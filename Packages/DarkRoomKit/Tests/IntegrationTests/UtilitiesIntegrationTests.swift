import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

@Suite("Library utilities against the test server", .enabled(if: TestServer.isAvailable), .serialized)
struct UtilitiesIntegrationTests {

    @Test func recentlyAddedLargeFilesAndFolders() async throws {
        let client = try await TestServer.client()
        let recent = try await LibraryUtilities.recentlyAdded(client, days: 3650)
        #expect(!recent.isEmpty)
        let large = try await LibraryUtilities.largeFiles(client, limit: 10)
        let sizes = large.compactMap { $0.exifInfo?.fileSizeInByte }
        #expect(sizes == sizes.sorted(by: >))
        let paths = try await client.getUniqueOriginalPaths()
        let tree = LibraryUtilities.folderTree(paths)
        #expect(!tree.isEmpty)
        let leaf = try #require(paths.first)
        #expect(!(try await LibraryUtilities.assets(inFolder: leaf, client: client)).isEmpty)
    }

    @Test func duplicatesAndMemoriesLoad() async throws {
        let client = try await TestServer.client()
        _ = try await client.getAssetDuplicates()
        _ = try await LibraryUtilities.memoriesForToday(client)
    }

    @Test func lockedFolderRoundTrip() async throws {
        let client = try await TestServer.client()
        let pin = "135790"
        if try await LibraryUtilities.lockedState(client) == .needsSetup {
            try await LibraryUtilities.setUpLockedFolderPIN(client, pin: pin)
        }
        try await LibraryUtilities.unlockLockedFolder(client, pin: pin)
        #expect(try await LibraryUtilities.lockedState(client) == .unlocked)
        // Use a throwaway upload so other suites never see a seeded photo disappear.
        let file = FileManager.default.temporaryDirectory.appending(path: "darkroom-locked-\(UUID().uuidString).png")
        try TinyPNG.random().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let target = try await client.upload(file: file, options: .init(fileCreatedAt: .now, fileModifiedAt: .now)).id
        defer { Task { try? await client.deleteAssets(body: AssetBulkDeleteDto(force: true, ids: [target])) } }
        let undo = try await AssetActions(client: client).setVisibility([target], .locked)
        let store = await TimelineStore(client: client, query: TimelineQuery(visibility: .locked, withStacked: false))
        await store.reload()
        await store.loadAll()
        #expect(await store.loadedAssets.contains { $0.id == target })
        try await undo.run()
        #expect(try await client.getAssetInfo(id: target).visibility == .timeline)
        try await LibraryUtilities.lockLockedFolder(client)
        #expect(try await LibraryUtilities.lockedState(client) == .locked)
    }
}
