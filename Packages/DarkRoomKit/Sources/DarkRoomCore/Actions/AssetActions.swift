import Foundation
import ImmichAPI

/// The reverse of an organising action, run by ⌘Z.
public struct UndoAction: Sendable {
    public var name: String
    public var run: @Sendable () async throws -> Void
    public init(name: String, run: @escaping @Sendable () async throws -> Void) {
        self.name = name
        self.run = run
    }
}

/// What changed, so views can update immediately (before Immich's live events arrive).
public enum AssetChange: Sendable {
    case favorite(ids: [String], Bool)
    case visibility(ids: [String], AssetVisibility)
    case trashed(ids: [String])
    case restored(ids: [String])
    case metadata(ids: [String])
    case albums(ids: [String])
    case stacked(ids: [String])
}

/// Organising actions on assets. Every action returns an `UndoAction` that puts things back.
/// Deleting only ever moves items to Immich's trash; nothing here deletes permanently except
/// `emptyTrash`, which callers must confirm.
public struct AssetActions: Sendable {
    public let client: ImmichClient

    public init(client: ImmichClient) { self.client = client }

    // MARK: Favourite, rating, description, visibility

    public func setFavorite(_ ids: [String], _ value: Bool) async throws -> UndoAction {
        let previous = try await details(ids)
        try await client.updateAssets(body: AssetBulkUpdateDto(ids: ids, isFavorite: value))
        return UndoAction(name: value ? "Favorite" : "Unfavorite") { [client] in
            for (old, group) in Dictionary(grouping: previous, by: \.isFavorite) {
                try await client.updateAssets(body: AssetBulkUpdateDto(ids: group.map(\.id), isFavorite: old))
            }
        }
    }

    /// Star rating 1–5; 0 clears it (Immich stores "unrated" as null).
    public func setRating(_ ids: [String], _ rating: Int) async throws -> UndoAction {
        let previous = try await details(ids)
        try await Self.rate(client, ids, rating)
        return UndoAction(name: "Rating") { [client] in
            for (old, group) in Dictionary(grouping: previous, by: { $0.exifInfo?.rating ?? 0 }) {
                try await Self.rate(client, group.map(\.id), old)
            }
        }
    }

    static func rate(_ client: ImmichClient, _ ids: [String], _ rating: Int) async throws {
        let value: JSONValue = rating <= 0 ? .null : .number(Double(min(5, rating)))
        _ = try await client.raw("PUT", "/assets", body: JSONValue.object(["ids": .array(ids.map(JSONValue.string)), "rating": value]))
    }

    public func setDescription(_ ids: [String], _ text: String) async throws -> UndoAction {
        let previous = try await details(ids)
        try await client.updateAssets(body: AssetBulkUpdateDto(description: text, ids: ids))
        return UndoAction(name: "Description") { [client] in
            for (old, group) in Dictionary(grouping: previous, by: { $0.exifInfo?.description ?? "" }) {
                try await client.updateAssets(body: AssetBulkUpdateDto(description: old, ids: group.map(\.id)))
            }
        }
    }

    /// Archive (`.archive`), unarchive (`.timeline`) or move to the locked folder (`.locked`).
    public func setVisibility(_ ids: [String], _ visibility: AssetVisibility) async throws -> UndoAction {
        let previous = try await details(ids)
        try await client.updateAssets(body: AssetBulkUpdateDto(ids: ids, visibility: visibility))
        let name = switch visibility {
        case .archive: "Archive"
        case .locked: "Move to Locked Folder"
        default: "Unarchive"
        }
        return UndoAction(name: name) { [client] in
            for (old, group) in Dictionary(grouping: previous, by: \.visibility) {
                try await client.updateAssets(body: AssetBulkUpdateDto(ids: group.map(\.id), visibility: old))
            }
        }
    }

    // MARK: Trash

    /// Moves to Immich's trash (recoverable for the server's retention period).
    public func trash(_ ids: [String]) async throws -> UndoAction {
        try await client.deleteAssets(body: AssetBulkDeleteDto(force: false, ids: ids))
        return UndoAction(name: "Move to Trash") { [client] in
            _ = try await client.restoreAssets(body: BulkIdsDto(ids: ids))
        }
    }

    public func restore(_ ids: [String]) async throws -> UndoAction {
        _ = try await client.restoreAssets(body: BulkIdsDto(ids: ids))
        return UndoAction(name: "Restore") { [client] in
            try await client.deleteAssets(body: AssetBulkDeleteDto(force: false, ids: ids))
        }
    }

    /// Permanently deletes everything in the trash. Not undoable; the caller confirms first.
    @discardableResult
    public func emptyTrash() async throws -> Int {
        try await client.emptyTrash().count
    }

    // MARK: Date and time

    /// Shifts capture dates by a fixed offset (e.g. a camera clock that was wrong).
    public func shiftDates(_ ids: [String], byMinutes minutes: Int) async throws -> UndoAction {
        try await client.updateAssets(body: AssetBulkUpdateDto(dateTimeRelative: minutes, ids: ids))
        return UndoAction(name: "Adjust Date & Time") { [client] in
            try await client.updateAssets(body: AssetBulkUpdateDto(dateTimeRelative: -minutes, ids: ids))
        }
    }

    /// Sets an exact capture date (local wall-clock time in `timeZone`).
    public func setDate(_ ids: [String], to date: Date, timeZone: TimeZone) async throws -> UndoAction {
        let previous = try await details(ids)
        try await client.updateAssets(body: AssetBulkUpdateDto(dateTimeOriginal: Self.exifDate(date, timeZone),
                                                              ids: ids, timeZone: timeZone.identifier))
        return UndoAction(name: "Set Date & Time") { [client] in
            for asset in previous {
                guard let original = asset.exifInfo?.dateTimeOriginal ?? Optional(asset.fileCreatedAt) else { continue }
                try await client.updateAssets(body: AssetBulkUpdateDto(dateTimeOriginal: original, ids: [asset.id],
                                                                      timeZone: asset.exifInfo?.timeZone))
            }
        }
    }

    /// ISO-8601 with the zone's offset, the form Immich stores in `dateTimeOriginal`.
    public static func exifDate(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: Location

    /// Sets a location. Immich can't clear a location, so undo restores previous coordinates only
    /// where the asset had them.
    public func setLocation(_ ids: [String], latitude: Double, longitude: Double) async throws -> UndoAction {
        let previous = try await details(ids)
        try await client.updateAssets(body: AssetBulkUpdateDto(ids: ids, latitude: latitude, longitude: longitude))
        return UndoAction(name: "Set Location") { [client] in
            for asset in previous {
                guard let lat = asset.exifInfo?.latitude, let lon = asset.exifInfo?.longitude else { continue }
                try await client.updateAssets(body: AssetBulkUpdateDto(ids: [asset.id], latitude: lat, longitude: lon))
            }
        }
    }

    // MARK: Albums

    public func addToAlbum(_ albumID: String, _ ids: [String]) async throws -> UndoAction {
        let results = try await client.addAssetsToAlbum(id: albumID, body: BulkIdsDto(ids: ids))
        let added = results.filter(\.success).map(\.id)
        return UndoAction(name: "Add to Album") { [client] in
            guard !added.isEmpty else { return }
            _ = try await client.removeAssetFromAlbum(id: albumID, body: BulkIdsDto(ids: added))
        }
    }

    public func removeFromAlbum(_ albumID: String, _ ids: [String]) async throws -> UndoAction {
        let results = try await client.removeAssetFromAlbum(id: albumID, body: BulkIdsDto(ids: ids))
        let removed = results.filter(\.success).map(\.id)
        return UndoAction(name: "Remove from Album") { [client] in
            guard !removed.isEmpty else { return }
            _ = try await client.addAssetsToAlbum(id: albumID, body: BulkIdsDto(ids: removed))
        }
    }

    /// Creates an album, optionally with assets. Undo deletes the album (not the photos).
    public func createAlbum(name: String, description: String = "", assetIDs: [String] = []) async throws -> (AlbumResponseDto, UndoAction) {
        let album = try await client.createAlbum(body: CreateAlbumDto(albumName: name, assetIds: assetIDs.isEmpty ? nil : assetIDs,
                                                                      description: description))
        return (album, UndoAction(name: "New Album") { [client] in try await client.deleteAlbum(id: album.id) })
    }

    // MARK: Tags

    public func tag(_ ids: [String], tagIDs: [String]) async throws -> UndoAction {
        let before = try await details(ids)
        _ = try await client.bulkTagAssets(body: TagBulkAssetsDto(assetIds: ids, tagIds: tagIDs))
        return UndoAction(name: "Add Tag") { [client] in
            for tagID in tagIDs {
                // Only untag assets that didn't already have the tag.
                let newly = before.filter { !($0.tags ?? []).contains { $0.id == tagID } }.map(\.id)
                if !newly.isEmpty { _ = try await client.untagAssets(id: tagID, body: BulkIdsDto(ids: newly)) }
            }
        }
    }

    public func untag(_ ids: [String], tagID: String) async throws -> UndoAction {
        let results = try await client.untagAssets(id: tagID, body: BulkIdsDto(ids: ids))
        let removed = results.filter(\.success).map(\.id)
        return UndoAction(name: "Remove Tag") { [client] in
            if !removed.isEmpty { _ = try await client.tagAssets(id: tagID, body: BulkIdsDto(ids: removed)) }
        }
    }

    // MARK: Stacks

    /// Stacks assets; the first id becomes the primary (the one shown in the timeline).
    public func stack(_ ids: [String]) async throws -> (StackResponseDto, UndoAction) {
        let stack = try await client.createStack(body: StackCreateDto(assetIds: ids))
        return (stack, UndoAction(name: "Stack") { [client] in try await client.deleteStack(id: stack.id) })
    }

    public func unstack(stackID: String) async throws -> UndoAction {
        let stack = try await client.getStack(id: stackID)
        let ids = [stack.primaryAssetId] + stack.assets.map(\.id).filter { $0 != stack.primaryAssetId }
        try await client.deleteStack(id: stackID)
        return UndoAction(name: "Unstack") { [client] in _ = try await client.createStack(body: StackCreateDto(assetIds: ids)) }
    }

    public func setStackPrimary(stackID: String, assetID: String) async throws -> UndoAction {
        let stack = try await client.getStack(id: stackID)
        let old = stack.primaryAssetId
        _ = try await client.updateStack(id: stackID, body: StackUpdateDto(primaryAssetId: assetID))
        return UndoAction(name: "Set Stack Cover") { [client] in
            _ = try await client.updateStack(id: stackID, body: StackUpdateDto(primaryAssetId: old))
        }
    }

    // MARK: Helpers

    /// Full asset records (concurrently, a few at a time) for remembering previous values.
    public func details(_ ids: [String]) async throws -> [AssetResponseDto] {
        try await withThrowingTaskGroup(of: AssetResponseDto.self) { group in
            var results: [AssetResponseDto] = []
            var iterator = ids.makeIterator()
            for _ in 0..<min(8, ids.count) {
                if let id = iterator.next() { group.addTask { [client] in try await client.getAssetInfo(id: id) } }
            }
            while let next = try await group.next() {
                results.append(next)
                if let id = iterator.next() { group.addTask { [client] in try await client.getAssetInfo(id: id) } }
            }
            return results
        }
    }
}

extension AssetActions {
    /// Make Still: unlinks the motion clip (Immich's own unlink) and moves it to Immich's trash.
    /// Undo restores the clip and links it again.
    public func makeStill(_ stillID: String) async throws -> UndoAction {
        let still = try await client.getAssetInfo(id: stillID)
        guard let motionID = still.livePhotoVideoId else { return UndoAction(name: "Make Still") {} }
        // livePhotoVideoId must be sent as an explicit null to unlink.
        _ = try await client.raw("PUT", "/assets/\(stillID)", body: JSONValue.object(["livePhotoVideoId": .null]))
        try await client.deleteAssets(body: AssetBulkDeleteDto(force: false, ids: [motionID]))
        return UndoAction(name: "Make Still") { [client] in
            _ = try await client.restoreAssets(body: BulkIdsDto(ids: [motionID]))
            _ = try await client.updateAsset(id: stillID, body: UpdateAssetDto(livePhotoVideoId: motionID))
            try await client.updateAssets(body: AssetBulkUpdateDto(ids: [motionID], visibility: .hidden))
        }
    }
}
