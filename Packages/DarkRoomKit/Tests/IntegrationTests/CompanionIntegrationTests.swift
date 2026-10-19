import Foundation
import Testing
import CoreImage
import ImmichAPI
@testable import DarkRoomCore

/// "Edit in…" without launching an app: a simulated editor saves into the working folder.
@Suite("Companion editors", .enabled(if: TestServer.isAvailable), .serialized)
struct CompanionIntegrationTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "darkroom-companion-\(UUID().uuidString)")

    func fakeEditor(_ returns: CompanionEditor.Return) -> CompanionEditor {
        CompanionEditor(id: "Fake", name: "Fake Editor", appURL: URL(fileURLWithPath: "/Applications/NotInstalled.app"),
                        returns: returns, workingExtension: nil, handlesRAW: false)
    }

    func session(_ editor: CompanionEditor, original: URL) throws -> EditSession {
        let folder = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appending(path: "Export"), withIntermediateDirectories: true)
        let copy = folder.appending(path: ".original-\(original.lastPathComponent)")
        let work = folder.appending(path: original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: copy)
        try FileManager.default.copyItem(at: original, to: work)
        return EditSession(assetID: "x", assetName: original.lastPathComponent, editor: editor, folder: folder, workFile: work,
                           originalCopy: copy, keepEditable: false)
    }

    /// "Edits" a JPEG: darker, saved over the same file (like Preview / Pixelmator).
    func saveEdit(_ url: URL) throws {
        var r = EditRecipe(); r.exposure = -1; r.monochrome = true
        let tmp = url.deletingLastPathComponent().appending(path: "tmp-\(url.lastPathComponent)")
        try RenderEngine.shared.export(original: url, recipe: r, to: tmp)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    @Test func onCloseResultBecomesAVersion() async throws {
        let client = try await TestServer.client()
        let manager = VersionManager(client: client, registry: VersionRegistry(file: root.appending(path: "r.json")))
        let id = try #require(TestServer.seeded["jpg"]?.first)
        let context = try await manager.context(for: id)
        let original = try await client.downloadOriginal(assetID: id, to: root.appending(path: context.original.originalFileName))
        let s = try session(fakeEditor(.onClose), original: original)
        #expect(try s.result() == nil, "Nothing saved yet")
        #expect(!s.isStillOpen(), "Editor isn't running")
        try await Task.sleep(for: .milliseconds(1100))
        try saveEdit(s.workFile)
        let result = try #require(try s.result())
        guard case .version(let versionID) = try await manager.saveExternal(result, context: context, originalFile: original, editor: "Fake Editor") else {
            Issue.record("no version"); return
        }
        let version = try await client.getAssetInfo(id: versionID)
        #expect(version.originalFileName.hasSuffix("-edit.jpg"))
        #expect(try await manager.record(of: versionID)?.editor == "Fake Editor")
        #expect(try await client.getAssetInfo(id: id).visibility == .hidden)
        try await manager.revert(try await manager.context(for: versionID))
        #expect(try await client.getAssetInfo(id: id).visibility == .timeline)
        try? await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: [versionID]))
    }

    @Test func watchedExportFolderAndInstalledEditors() throws {
        let src = root.appending(path: "src.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let img = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try RenderEngine.shared.context.writeJPEGRepresentation(of: img, to: src, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let s = try session(fakeEditor(.watchedExport), original: src)
        #expect(try s.result() == nil)
        try FileManager.default.copyItem(at: src, to: s.exportFolder.appending(path: "exported.jpg"))
        #expect(try s.result()?.lastPathComponent == "exported.jpg")
        // Preview is always present on macOS.
        #expect(CompanionEditor.installed().contains { $0.name == "Preview" })
    }
}
