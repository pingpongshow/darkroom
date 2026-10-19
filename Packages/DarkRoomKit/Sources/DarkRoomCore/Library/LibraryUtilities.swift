import Foundation
import ImmichAPI

/// Recently added, large files, folders, duplicates, bursts, memories and the locked folder.
public enum LibraryUtilities {

    // MARK: Collections built from search

    /// Items uploaded in the last `days` days, newest upload first.
    public static func recentlyAdded(_ client: ImmichClient, days: Int = 30, limit: Int = 1000) async throws -> [TimelineAsset] {
        var results: [AssetResponseDto] = []
        var page = 1
        let since = ImmichDate.format(Date().addingTimeInterval(-Double(days) * 86_400))
        while results.count < limit {
            let response = try await client.searchAssets(body: MetadataSearchDto(createdAfter: since, page: page, size: 250,
                                                                                visibility: .timeline, withExif: true, withStacked: true))
            results += response.assets.items
            guard let next = response.assets.nextPage.flatMap(Int.init), next > page else { break }
            page = next
        }
        return results.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map(TimelineAsset.init)
    }

    /// DarkRoom's edited versions (`<name>-edit.<ext>`), most recently saved first.
    public static func recentlyEdited(_ client: ImmichClient, limit: Int = 500) async throws -> [TimelineAsset] {
        var results: [AssetResponseDto] = []
        var page = 1
        while results.count < limit {
            let response = try await client.searchAssets(body: MetadataSearchDto(originalFileName: "-edit.", page: page, size: 250,
                                                                                visibility: .timeline, withExif: true, withStacked: true))
            results += response.assets.items.filter { $0.originalFileName.contains("-edit.") && !$0.isTrashed }
            guard let next = response.assets.nextPage.flatMap(Int.init), next > page else { break }
            page = next
        }
        return results.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map(TimelineAsset.init)
    }

    /// Largest files first (photos and videos), for freeing up space.
    public static func largeFiles(_ client: ImmichClient, limit: Int = 250) async throws -> [AssetResponseDto] {
        // `orderBy` can't be combined with the deprecated `page` / `order` fields.
        // (`visibility` can't be combined with `orderBy` either, so hidden motion clips and superseded files are
        // filtered here.)
        try await client.searchAssets(body: MetadataSearchDto(
            orderBy: SearchOrder(direction: .desc, field: .fileSizeInBytes), size: limit * 2, withExif: true)).assets.items
            .filter { $0.visibility == .timeline && !$0.isTrashed }
            .prefix(limit).map { $0 }
    }

    // MARK: Folders

    /// A folder in the library's original paths (Immich's folder view).
    public struct Folder: Identifiable, Hashable, Sendable {
        public var path: String
        public var name: String
        public var children: [Folder]
        public var id: String { path }
        public var childrenOrNil: [Folder]? { children.isEmpty ? nil : children }
    }

    /// Builds a tree from Immich's unique original folder paths, collapsing single-child chains
    /// at the top (e.g. "/data/library/<user>").
    public static func folderTree(_ paths: [String]) -> [Folder] {
        final class Node { var children: [String: Node] = [:] }
        let root = Node()
        for path in paths {
            var node = root
            for part in path.split(separator: "/").map(String.init) {
                if node.children[part] == nil { node.children[part] = Node() }
                node = node.children[part]!
            }
        }
        func build(_ node: Node, prefix: String) -> [Folder] {
            node.children.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
                let path = prefix + "/" + name
                return Folder(path: path, name: name, children: build(node.children[name]!, prefix: path))
            }
        }
        var top = build(root, prefix: "")
        while top.count == 1, let only = top.first, !only.children.isEmpty, !paths.contains(only.path) { top = only.children }
        return top
    }

    /// Photos in a folder and (like Lightroom's default) its subfolders.
    public static func assets(inFolder path: String, client: ImmichClient, includeSubfolders: Bool = true) async throws -> [TimelineAsset] {
        var folders = [path]
        if includeSubfolders {
            folders += try await client.getUniqueOriginalPaths().filter { $0.hasPrefix(path + "/") }
        }
        var all: [AssetResponseDto] = []
        for folder in folders { all += try await client.getAssetsByOriginalPath(path: folder) }
        return all
            .filter { $0.visibility == .timeline || $0.visibility == .archive }
            .sorted { $0.fileCreatedAt > $1.fileCreatedAt }
            .map(TimelineAsset.init)
    }

    // MARK: Duplicates

    /// Keeps the chosen assets and moves the rest of the group to Immich's trash.
    public static func resolveDuplicates(_ client: ImmichClient, group: DuplicateResponseDto, keep: Set<String>) async throws {
        let all = group.assets.map(\.id)
        _ = try await client.resolveDuplicates(body: DuplicateResolveDto(groups: [
            DuplicateResolveGroupDto(duplicateId: group.duplicateId, keepAssetIds: all.filter { keep.contains($0) },
                                     trashAssetIds: all.filter { !keep.contains($0) })]))
    }

    /// Stacks the group (chosen asset as cover) and marks it as not duplicate.
    public static func stackDuplicates(_ client: ImmichClient, group: DuplicateResponseDto, cover: String) async throws {
        let ids = [cover] + group.assets.map(\.id).filter { $0 != cover }
        _ = try await client.createStack(body: StackCreateDto(assetIds: ids))
        _ = try await client.resolveDuplicates(body: DuplicateResolveDto(groups: [
            DuplicateResolveGroupDto(duplicateId: group.duplicateId, keepAssetIds: ids, trashAssetIds: [])]))
    }

    // MARK: Bursts

    /// Rapid sequences of photos (≥ `minimumFrames`, each within `maxGap` seconds of the previous, same
    /// owner and shape) that aren't already stacked: iPhone and camera bursts.
    public static func bursts(in assets: [TimelineAsset], maxGap: TimeInterval = 1.0, minimumFrames: Int = 3) -> [[TimelineAsset]] {
        let photos = assets.filter { $0.isImage && !$0.isLivePhoto && $0.stackID == nil }
            .sorted { $0.fileCreatedAt < $1.fileCreatedAt }
        var groups: [[TimelineAsset]] = []
        var current: [TimelineAsset] = []
        for photo in photos {
            if let last = current.last, photo.ownerID == last.ownerID, abs(photo.ratio - last.ratio) < 0.01,
               photo.fileCreatedAt.timeIntervalSince(last.fileCreatedAt) <= maxGap {
                current.append(photo)
            } else {
                if current.count >= minimumFrames { groups.append(current) }
                current = [photo]
            }
        }
        if current.count >= minimumFrames { groups.append(current) }
        return groups.reversed()
    }

    /// Keeps `picks` (first pick becomes the cover) and stacks the other frames under it.
    public static func stackBurst(_ client: ImmichClient, frames: [String], picks: [String]) async throws -> UndoAction {
        guard let cover = picks.first else { throw CancellationError() }
        let ids = [cover] + frames.filter { $0 != cover }
        let stack = try await client.createStack(body: StackCreateDto(assetIds: ids))
        return UndoAction(name: "Stack Burst") { try await client.deleteStack(id: stack.id) }
    }

    // MARK: Memories

    /// Today's "On this day" (and other) memories that Immich generated.
    public static func memoriesForToday(_ client: ImmichClient) async throws -> [MemoryResponseDto] {
        let day = Date().formatted(.iso8601.year().month().day())
        return try await client.searchMemories(for: day)
            .filter { !$0.assets.isEmpty && $0.deletedAt == nil }
            .sorted { $0.data.year > $1.data.year }
    }

    /// Every memory Immich has made (newest first), for the Memories view.
    public static func allMemories(_ client: ImmichClient) async throws -> [MemoryResponseDto] {
        try await client.searchMemories()
            .filter { !$0.assets.isEmpty && $0.deletedAt == nil }
            .sorted { $0.memoryAt > $1.memoryAt }
    }

    // MARK: Locked folder (Immich's own PIN, separate from the DarkRoom PIN)

    public enum LockedState: Sendable, Equatable { case needsSetup, locked, unlocked }

    public static func lockedState(_ client: ImmichClient) async throws -> LockedState {
        let status = try await client.getAuthStatus()
        if !status.pinCode { return .needsSetup }
        return status.isElevated ? .unlocked : .locked
    }

    public static func setUpLockedFolderPIN(_ client: ImmichClient, pin: String) async throws {
        try await client.setupPinCode(body: PinCodeSetupDto(pinCode: pin))
    }

    public static func unlockLockedFolder(_ client: ImmichClient, pin: String) async throws {
        try await client.unlockAuthSession(body: SessionUnlockDto(pinCode: pin))
    }

    public static func lockLockedFolder(_ client: ImmichClient) async throws {
        try await client.lockAuthSession()
    }
}
