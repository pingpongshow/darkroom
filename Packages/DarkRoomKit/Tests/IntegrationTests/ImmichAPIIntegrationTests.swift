import Foundation
import Testing
import ImmichAPI

@Suite("Immich API against the stock test server", .enabled(if: TestServer.isAvailable), .serialized)
struct ImmichAPIIntegrationTests {

    @Test func serverVersionMatchesGeneratedAPI() async throws {
        let client = ImmichClient(serverURL: TestServer.url)
        let version = try await client.getServerVersion()
        #expect("v\(version.major).\(version.minor).\(version.patch)" == ImmichAPIVersion.generatedFrom)
    }

    @Test func loginAndCurrentUser() async throws {
        let client = try await TestServer.client()
        let me = try await client.getMyUser()
        #expect(me.email == TestServer.credentials!.admin.email)
        #expect(me.isAdmin)
    }

    @Test func badPasswordIsRejected() async throws {
        let client = ImmichClient(serverURL: TestServer.url)
        await #expect(throws: ImmichError.self) {
            _ = try await client.login(body: LoginCredentialDto(email: TestServer.credentials!.admin.email, password: "wrong-password"))
        }
    }

    @Test func timelineBucketsDecode() async throws {
        let client = try await TestServer.client()
        let buckets = try await client.getTimeBuckets(withStacked: true)
        #expect(!buckets.isEmpty)
        let first = try #require(buckets.first)
        let assets = try await client.getTimeBucket(timeBucket: first.timeBucket, withStacked: true)
        #expect(assets.id.count == first.count)
        #expect(assets.isImage.count == assets.id.count)
        #expect(assets.ratio.count == assets.id.count)
    }

    @Test func assetDetailsDecodeForEveryCategory() async throws {
        let client = try await TestServer.client()
        let ids = TestServer.seeded.filter { !["album", "viewer"].contains($0.key) }.values.flatMap { $0 }
        #expect(ids.count >= 20)
        for id in ids {
            let asset = try await client.getAssetInfo(id: id)
            #expect(asset.id == id)
        }
    }

    @Test func livePhotoAndStackAreLinked() async throws {
        let client = try await TestServer.client()
        let live = try #require(TestServer.seeded["live-heic-portrait"]?.first)
        #expect(try await client.getAssetInfo(id: live).livePhotoVideoId != nil)
        let pair = try #require(TestServer.seeded["raw-jpeg-pair"]?.first)
        #expect(try await client.getAssetInfo(id: pair).stack != nil)
    }

    @Test func thumbnailsArePictures() async throws {
        let client = try await TestServer.client()
        let id = try #require(TestServer.seeded["jpg"]?.first)
        let thumb = try await client.thumbnail(assetID: id, size: .thumbnail)
        let preview = try await client.thumbnail(assetID: id, size: .preview)
        #expect(thumb.count > 500)
        #expect(preview.count > thumb.count)
    }

    @Test func libraryViewsDecode() async throws {
        let client = try await TestServer.client()
        let albums = try await client.getAllAlbums()
        #expect(albums.contains { $0.albumName == "Sample Album" })
        _ = try await client.getAllPeople()
        _ = try await client.getMapMarkers()
        _ = try await client.getAllTags()
        _ = try await client.searchMemories()
        _ = try await client.getExploreData()
        let search = try await client.searchAssets(body: MetadataSearchDto(size: 5))
        #expect(!search.assets.items.isEmpty)
        let stats = try await client.getAssetStatistics()
        #expect(stats.total > 0)
    }

    @Test func uploadThenTrashAndDelete() async throws {
        let client = try await TestServer.client()
        let file = FileManager.default.temporaryDirectory.appending(path: "darkroom-it-\(UUID().uuidString).png")
        try TinyPNG.random().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await client.upload(file: file, options: .init(fileCreatedAt: .now, fileModifiedAt: .now))
        #expect(result.status == .created)
        let info = try await client.getAssetInfo(id: result.id)
        #expect(info.originalFileName.hasSuffix(".png"))
        try await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: [result.id]))
    }

    @Test func liveEventsArrive() async throws {
        let client = try await TestServer.client()
        let socket = ImmichSocket(client: client)
        let id = try #require(TestServer.seeded["heic"]?.first)
        let events = socket.events()
        defer { socket.stop() }
        var iterator = events.makeAsyncIterator()
        // Wait for the namespace connection, then trigger an update.
        let connected = await iterator.next()
        #expect(connected == .connected)
        let before = try await client.getAssetInfo(id: id).isFavorite
        try await client.updateAsset(id: id, body: UpdateAssetDto(isFavorite: !before))
        var sawUpdate = false
        for _ in 0..<10 {
            if case .assetUpdate(let updated) = await iterator.next(), updated == id { sawUpdate = true; break }
        }
        try await client.updateAsset(id: id, body: UpdateAssetDto(isFavorite: before))
        #expect(sawUpdate)
    }
}

/// Generates a small, unique PNG so uploads never collide with Immich's duplicate detection.
enum TinyPNG {
    static func random() -> Data {
        // 1x1 RGBA PNG with a random pixel; CRCs computed below.
        var pixel = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { pixel[i] = UInt8.random(in: 0...255) }
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let typeBytes = Array(type.utf8)
            var out = withUnsafeBytes(of: UInt32(data.count).bigEndian, Array.init) + typeBytes + data
            out += withUnsafeBytes(of: crc32(typeBytes + data).bigEndian, Array.init)
            return out
        }
        let ihdr: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]
        let raw: [UInt8] = [0] + pixel
        let idat = zlibStored(raw)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", [])
        return Data(png)
    }

    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let len = UInt16(data.count)
        return [0x78, 0x01, 0x01, UInt8(len & 0xFF), UInt8(len >> 8), UInt8(~len & 0xFF), UInt8(~len >> 8)]
            + data + withUnsafeBytes(of: ((b << 16) | a).bigEndian, Array.init)
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}
