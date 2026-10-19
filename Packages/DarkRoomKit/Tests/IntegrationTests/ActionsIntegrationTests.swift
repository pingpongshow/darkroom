import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

/// Every action is applied, checked, then undone and checked again so the seeded library is unchanged.
@Suite("Organising actions with undo", .enabled(if: TestServer.isAvailable), .serialized)
struct ActionsIntegrationTests {
    func ids(_ key: String) throws -> [String] { try #require(TestServer.seeded[key]) }

    @Test func favoriteRatingDescriptionUndo() async throws {
        let client = try await TestServer.client()
        let actions = AssetActions(client: client)
        let targets = try ids("heic")
        let before = try await actions.details(targets)

        let fav = try await actions.setFavorite(targets, true)
        #expect(try await actions.details(targets).allSatisfy(\.isFavorite))
        try await fav.run()
        let favs = Dictionary(uniqueKeysWithValues: try await actions.details(targets).map { ($0.id, $0.isFavorite) })
        for asset in before { #expect(favs[asset.id] == asset.isFavorite) }

        let rating = try await actions.setRating(targets, 3)
        #expect(try await actions.details(targets).allSatisfy { $0.exifInfo?.rating == 3 })
        try await rating.run()
        let ratings = Dictionary(uniqueKeysWithValues: try await actions.details(targets).map { ($0.id, $0.exifInfo?.rating ?? 0) })
        for asset in before { #expect(ratings[asset.id] == (asset.exifInfo?.rating ?? 0)) }

        let description = try await actions.setDescription(targets, "DarkRoom test caption")
        #expect(try await actions.details(targets).allSatisfy { $0.exifInfo?.description == "DarkRoom test caption" })
        try await description.run()
        #expect(try await actions.details(targets).allSatisfy { $0.exifInfo?.description != "DarkRoom test caption" })
    }

    @Test func archiveAndTrashAreReversible() async throws {
        let client = try await TestServer.client()
        let actions = AssetActions(client: client)
        let targets = try ids("jpg")

        let archive = try await actions.setVisibility(targets, .archive)
        #expect(try await actions.details(targets).allSatisfy { $0.visibility == .archive })
        try await archive.run()
        #expect(try await actions.details(targets).allSatisfy { $0.visibility == .timeline })

        let trash = try await actions.trash(targets)
        #expect(try await actions.details(targets).allSatisfy(\.isTrashed))
        try await trash.run()
        #expect(try await actions.details(targets).allSatisfy { !$0.isTrashed })
    }

    @Test func dateShiftAndSetUndo() async throws {
        let client = try await TestServer.client()
        let actions = AssetActions(client: client)
        let target = [try ids("png")[0]]
        let original = try #require(try await actions.details(target).first)
        let originalDate = try #require(ImmichDate.parse(original.fileCreatedAt))

        let shift = try await actions.shiftDates(target, byMinutes: 72)
        try await waitFor { try await actions.details(target).first.flatMap { ImmichDate.parse($0.fileCreatedAt) } == originalDate.addingTimeInterval(72 * 60) }
        try await shift.run()
        try await waitFor { try await actions.details(target).first.flatMap { ImmichDate.parse($0.fileCreatedAt) } == originalDate }

        let newDate = ISO8601DateFormatter().date(from: "2020-05-17T10:30:00Z")!
        let set = try await actions.setDate(target, to: newDate, timeZone: TimeZone(identifier: "Europe/Paris")!)
        try await waitFor { try await actions.details(target).first.flatMap { ImmichDate.parse($0.fileCreatedAt) } == newDate }
        try await set.run()
        try await waitFor { try await actions.details(target).first.flatMap { ImmichDate.parse($0.fileCreatedAt) } == originalDate }
    }

    @Test func locationUndoRestoresPreviousCoordinates() async throws {
        let client = try await TestServer.client()
        let actions = AssetActions(client: client)
        let located = try await actions.details(try ids("live-heic-landscape")).filter { $0.exifInfo?.latitude != nil }
        let target = try #require(located.first)
        let undo = try await actions.setLocation([target.id], latitude: 48.8584, longitude: 2.2945)
        try await waitFor { try await actions.details([target.id]).first?.exifInfo?.latitude.map { abs($0 - 48.8584) < 0.001 } == true }
        try await undo.run()
        try await waitFor {
            try await actions.details([target.id]).first?.exifInfo?.latitude.map { abs($0 - target.exifInfo!.latitude!) < 0.0001 } == true
        }
    }

    @Test func albumsTagsAndStacks() async throws {
        let client = try await TestServer.client()
        let actions = AssetActions(client: client)
        let targets = try ids("heic")

        let (album, deleteAlbum) = try await actions.createAlbum(name: "DarkRoom Test Album", assetIDs: [targets[0]])
        let add = try await actions.addToAlbum(album.id, Array(targets.dropFirst()))
        #expect(try await client.getAlbumInfo(id: album.id).assetCount == targets.count)
        try await add.run()
        #expect(try await client.getAlbumInfo(id: album.id).assetCount == 1)
        try await deleteAlbum.run()
        #expect(try await client.getAllAlbums().allSatisfy { $0.id != album.id })

        let tag = try await client.upsertTags(body: TagUpsertDto(tags: ["DarkRoom/Test"])).last!
        let tagUndo = try await actions.tag(targets, tagIDs: [tag.id])
        #expect(try await actions.details(targets).allSatisfy { ($0.tags ?? []).contains { $0.id == tag.id } })
        try await tagUndo.run()
        // Stays removed even if a pending Immich sidecar job briefly puts the tag back.
        #expect(try await eventually { try await actions.details(targets).allSatisfy { !($0.tags ?? []).contains { $0.id == tag.id } } })
        try await Task.sleep(for: .seconds(11))
        #expect(try await actions.details(targets).allSatisfy { !($0.tags ?? []).contains { $0.id == tag.id } })
        // Deleting the parent removes its children.
        for t in try await client.getAllTags() where t.value == "DarkRoom" { try await client.deleteTag(id: t.id) }
        #expect(try await client.getAllTags().allSatisfy { !$0.value.hasPrefix("DarkRoom") })

        let (stack, unstack) = try await actions.stack(targets)
        #expect(stack.primaryAssetId == targets[0])
        let cover = try await actions.setStackPrimary(stackID: stack.id, assetID: targets[1])
        #expect(try await client.getStack(id: stack.id).primaryAssetId == targets[1])
        try await cover.run()
        #expect(try await client.getStack(id: stack.id).primaryAssetId == targets[0])
        try await unstack.run()
        #expect(try await actions.details(targets).allSatisfy { $0.stack == nil })
    }

    /// Date and location edits are applied by a background job; poll briefly.
    func waitFor(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<40 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("Condition not met in time")
    }
}
