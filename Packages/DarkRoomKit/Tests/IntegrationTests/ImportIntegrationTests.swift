import Foundation
import Testing
import CoreImage
import ImmichAPI
@testable import DarkRoomCore

@Suite("Import", .enabled(if: TestServer.isAvailable), .serialized)
struct ImportIntegrationTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "darkroom-import-\(UUID().uuidString)")

    /// A unique small image (random colour so the checksum is new).
    func newImage(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        let c = CIColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1))
        let img = CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
        if name.hasSuffix(".png") {
            try RenderEngine.shared.context.writePNGRepresentation(of: img, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        } else {
            try RenderEngine.shared.context.writeJPEGRepresentation(of: img, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return url
    }

    @Test func pairsLivePhotosAndRawJpegAndSkipsDuplicates() async throws {
        let client = try await TestServer.client()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Live Photo straight from the server (still + motion), so both are already in Immich.
        let stillID = try #require(TestServer.seeded["live-heic-portrait"]?.last)
        let still = try await client.getAssetInfo(id: stillID)
        let motion = try await client.getAssetInfo(id: try #require(still.livePhotoVideoId))
        _ = try await client.downloadOriginal(assetID: still.id, to: folder.appending(path: "IMG_1.HEIC"))
        _ = try await client.downloadOriginal(assetID: motion.id, to: folder.appending(path: "IMG_1_motion.MOV"))
        // RAW + JPEG pair by name (the RAW is a seeded file; the JPEG is new).
        let cr3 = try #require(TestServer.seeded["cr3"])
        let rawID = try #require(cr3.first)
        _ = try await client.downloadOriginal(assetID: rawID, to: folder.appending(path: "IMG_2.CR3"))
        _ = try newImage("IMG_2.JPG")

        var items = await ImportScanner.items(from: ImportScanner.files(in: [folder]))
        let live = try #require(items.first { $0.file.lastPathComponent == "IMG_1.HEIC" })
        #expect(live.kind == .livePhoto && live.motion?.lastPathComponent == "IMG_1_motion.MOV", "Paired by Apple content identifier")
        let raw = try #require(items.first { $0.file.lastPathComponent == "IMG_2.CR3" })
        #expect(raw.partner?.lastPathComponent == "IMG_2.JPG")
        #expect(items.count == 2)

        try await ImportScanner.markExisting(&items, client: client)
        #expect(items.first { $0.kind == .livePhoto }?.alreadyInImmich == true)
        #expect(items.first { $0.kind == .livePhoto }?.isSelected == false)
    }

    @Test func uploadsWithAlbumAndTags() async throws {
        let client = try await TestServer.client()
        let a = try newImage("new-a.jpg"), b = try newImage("new-b.png")
        var items = await ImportScanner.items(from: [a, b])
        try await ImportScanner.markExisting(&items, client: client)
        #expect(items.allSatisfy { !$0.alreadyInImmich })
        var options = ImportOptions()
        options.newAlbumName = "DarkRoom Import Test"
        options.tags = ["DarkRoom/Imported"]
        let queue = ImportQueue(client: client, file: folder.appending(path: "queue.json"))
        _ = await queue.add(items, options: options)
        await queue.run()
        #expect(await queue.pendingCount == 0, "Finished jobs leave the queue")
        let album = try #require(try await client.getAllAlbums().first { $0.albumName == "DarkRoom Import Test" })
        let info = try await client.getAlbumInfo(id: album.id)
        #expect(info.assetCount == 2)
        let search = try await client.searchAssets(body: MetadataSearchDto(albumIds: [album.id], withExif: true)).assets.items
        for asset in search {
            let full = try await client.getAssetInfo(id: asset.id)
            #expect((full.tags ?? []).contains { $0.value == "DarkRoom/Imported" }, "Tagged")
        }
        // Clean up the test uploads (fixtures created by this test).
        try await client.deleteAlbum(id: album.id)
        try await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: search.map(\.id)))
        for t in try await client.getAllTags() where t.value == "DarkRoom" { try await client.deleteTag(id: t.id) }
    }
}
