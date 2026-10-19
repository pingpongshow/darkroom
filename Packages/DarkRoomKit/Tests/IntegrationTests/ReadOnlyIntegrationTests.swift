import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

/// Read-only mode (used first against a real library): reads work, every change is refused before it is sent.
@Suite("Read-only mode", .enabled(if: TestServer.isAvailable), .serialized)
struct ReadOnlyIntegrationTests {
    @Test func readsWorkAndWritesAreRefused() async throws {
        let client = try await TestServer.client()
        client.writes.isReadOnly = true
        defer { client.writes.isReadOnly = false }
        let id = try #require(TestServer.seeded["jpg"]?.first)
        let before = try await client.getAssetInfo(id: id)
        #expect(try await client.searchAssets(body: MetadataSearchDto(size: 5)).assets.items.count > 0)
        _ = try await client.getAllAlbums()

        await #expect(throws: ImmichError.readOnly) {
            _ = try await client.updateAsset(id: id, body: UpdateAssetDto(isFavorite: !(before.isFavorite)))
        }
        await #expect(throws: ImmichError.readOnly) {
            _ = try await AssetActions(client: client).trash([id])
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "darkroom-it-ro-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: ImmichError.readOnly) {
            _ = try await client.upload(file: file, options: .init(fileCreatedAt: .now, fileModifiedAt: .now))
        }
        // Nothing changed, and a derived client shares the policy.
        #expect(try await client.getAssetInfo(id: id).isFavorite == before.isFavorite)
        #expect(try await client.getAssetInfo(id: id).isTrashed == false)
        #expect(client.with(credential: client.credential).writes.isReadOnly)
    }
}
