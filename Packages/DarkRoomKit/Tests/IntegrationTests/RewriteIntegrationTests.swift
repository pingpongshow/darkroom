import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

@Suite("Metadata written into files", .enabled(if: TestServer.isAvailable), .serialized)
struct RewriteIntegrationTests {
    static let exiftool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Vendor/exiftool/exiftool")
    let work = FileManager.default.temporaryDirectory.appending(path: "darkroom-rewrite-tests-\(UUID().uuidString)")

    func rewriter(_ client: ImmichClient) -> MetadataRewriter {
        let versions = VersionManager(client: client, registry: VersionRegistry(file: work.appending(path: "registry.json")))
        return MetadataRewriter(client: client, versions: versions, writer: MetadataWriter(exiftool: Self.exiftool),
                                originals: OriginalCache(client: client, accountID: UUID()))
    }

    func readTag(_ file: URL, _ tag: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [Self.exiftool.path, "-s3", "-\(tag)", file.path]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @Test func descriptionAndLocationEndUpInsideTheFile() async throws {
        let client = try await TestServer.client()
        let id = try #require(TestServer.seeded["jpg"]?.last)
        let actions = AssetActions(client: client)
        let (album, deleteAlbum) = try await actions.createAlbum(name: "DarkRoom Rewrite Test", assetIDs: [id])
        defer { Task { try? await deleteAlbum.run() } }
        let undoDescription = try await actions.setDescription([id], "Written by DarkRoom")
        let undoLocation = try await actions.setLocation([id], latitude: 35.0116, longitude: 135.7681)
        try await Task.sleep(for: .seconds(1))

        let result = try await rewriter(client).rewrite(id)
        let newID = try #require(result.replaced[id])
        let new = try await client.getAssetInfo(id: newID)
        let old = try await client.getAssetInfo(id: id)
        #expect(new.originalFileName == old.originalFileName)
        #expect(old.visibility == .hidden, "Superseded file is hidden, not trashed")
        #expect(!old.isTrashed)
        #expect(try await client.getAllAlbums(assetId: newID).contains { $0.id == album.id })

        let file = try await client.downloadOriginal(assetID: newID, to: work.appending(path: "check.jpg"))
        #expect(try readTag(file, "Description") == "Written by DarkRoom")
        #expect(try readTag(file, "GPSLatitude").hasPrefix("35 deg 0'"))

        // Undo brings the old file back and trashes the new one.
        try await result.undo.run()
        #expect(try await client.getAssetInfo(id: id).visibility == .timeline)
        #expect(try await client.getAssetInfo(id: newID).isTrashed)
        try await undoLocation.run()
        try await undoDescription.run()
        try? await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: [newID]))
        try? await client.deleteAssetMetadata(id: id, key: MetadataRewriter.supersededKey)
    }

    @Test func livePhotoKeepsItsMotionLinked() async throws {
        let client = try await TestServer.client()
        let id = try #require(TestServer.seeded["live-heic-portrait"]?.first)
        let before = try await client.getAssetInfo(id: id)
        let oldMotion = try #require(before.livePhotoVideoId)
        let result = try await rewriter(client).rewrite(id)
        let newID = try #require(result.replaced[id])
        let new = try await client.getAssetInfo(id: newID)
        let newMotion = try #require(new.livePhotoVideoId, "Still is linked to a rewritten motion clip")
        #expect(newMotion != oldMotion)
        guard newMotion != oldMotion, newID != id else { return }   // never delete the seeded clip
        #expect(try await client.getAssetInfo(id: newMotion).visibility == .hidden)
        try await result.undo.run()
        #expect(try await client.getAssetInfo(id: id).livePhotoVideoId == oldMotion)
        #expect(try await client.getAssetInfo(id: id).visibility == .timeline)
        try? await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: [newID, newMotion].filter { $0 != id && $0 != oldMotion }))
        try? await client.deleteAssetMetadata(id: id, key: MetadataRewriter.supersededKey)
    }
}
