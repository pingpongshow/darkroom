import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

@Suite("Library core against the test server", .enabled(if: TestServer.isAvailable), .serialized)
@MainActor
struct LibraryIntegrationTests {

    @Test func timelineLoadsSectionsOnDemand() async throws {
        let client = try await TestServer.client()
        let store = TimelineStore(client: client, query: .photos)
        await store.reload()
        #expect(store.error == nil)
        #expect(!store.sections.isEmpty)
        #expect(store.sections.allSatisfy { !$0.isLoaded })
        let first = try #require(store.sections.first)
        await store.loadSection(first.bucket)
        let loaded = try #require(store.sections.first?.assets)
        #expect(loaded.count == first.count)
        // Stacked RAW+JPEG pair shows once (primary only) with a stack count.
        await store.loadAll()
        let stacked = store.loadedAssets.filter { $0.stackID != nil }
        #expect(stacked.allSatisfy { ($0.stackCount ?? 0) >= 2 })
        // Live photos are flagged, hidden motion clips never appear.
        #expect(store.loadedAssets.contains { $0.isLivePhoto })
        #expect(!store.loadedAssets.contains { $0.visibility == .hidden })
    }

    @Test func favoritesAndAlbumQueries() async throws {
        let client = try await TestServer.client()
        let favorites = TimelineStore(client: client, query: .favorites)
        await favorites.reload()
        await favorites.loadAll()
        #expect(favorites.loadedAssets.count >= 2)
        #expect(favorites.loadedAssets.allSatisfy { $0.isFavorite })

        let albumID = try #require(TestServer.seeded["album"]?.first)
        let album = TimelineStore(client: client, query: .album(albumID))
        await album.reload()
        #expect(album.totalCount == 4)
    }

    @Test func imagePipelineCachesToDisk() async throws {
        let client = try await TestServer.client()
        let dir = FileManager.default.temporaryDirectory.appending(path: "dr-pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pipeline = ImagePipeline(client: client, accountID: UUID(), directory: dir)
        let id = try #require(TestServer.seeded["heic"]?.first)
        let key = ImagePipeline.Key(assetID: id, size: .thumbnail, cacheKey: "k1")
        let image = try await pipeline.image(key, maxPixel: 256)
        #expect(max(image.width, image.height) <= 256)
        #expect(await pipeline.diskUsageBytes > 0)
        // Second request is served from memory/disk.
        _ = try await pipeline.image(key, maxPixel: 256)
        let preview = try await pipeline.image(.init(assetID: id, size: .preview, cacheKey: "k1"))
        #expect(preview.width > image.width)
    }

    @Test func thumbhashDecodes() async throws {
        let client = try await TestServer.client()
        let store = TimelineStore(client: client, query: .photos)
        await store.reload()
        await store.loadAll()
        let hashes = store.loadedAssets.compactMap(\.thumbhash)
        #expect(!hashes.isEmpty)
        for hash in hashes {
            let image = try #require(ThumbHash.cgImage(base64: hash))
            #expect(image.width > 0 && image.width <= 32 && image.height <= 32)
        }
    }
}
