import Foundation
import Synchronization
import ImmichAPI

/// Keeps tag removals removed.
///
/// Immich writes tags into the XMP sidecar in a background job and re-imports the sidecar after other
/// metadata changes. If a tag is removed while such a job is pending, the old sidecar puts the tag back
/// a moment later. DarkRoom re-checks for a few seconds after each removal and removes it again, unless
/// DarkRoom itself re-added that tag in the meantime.
public enum TagRemoval {
    /// Seconds between re-checks after a removal.
    static let checks: [Double] = [2, 3, 5]
    private static let pending = Mutex<Set<String>>([])
    private static func key(_ tagID: String, _ assetID: String) -> String { tagID + "|" + assetID }

    /// Removes the tag and keeps watching it in the background.
    @discardableResult
    public static func remove(_ tagID: String, from ids: [String], client: ImmichClient) async throws -> [BulkIdResponseDto] {
        let results = try await client.untagAssets(id: tagID, body: BulkIdsDto(ids: ids))
        pending.withLock { set in for id in ids { set.insert(key(tagID, id)) } }
        Task.detached { try? await settle(tagID, ids: ids, client: client) }
        return results
    }

    /// Call when DarkRoom adds tags, so a pending re-check doesn't remove them again.
    public static func added(_ tagIDs: [String], to ids: [String]) {
        pending.withLock { set in for t in tagIDs { for id in ids { set.remove(key(t, id)) } } }
    }

    static func settle(_ tagID: String, ids: [String], client: ImmichClient) async throws {
        for delay in checks {
            try await Task.sleep(for: .seconds(delay))
            let watched = pending.withLock { set in ids.filter { set.contains(key(tagID, $0)) } }
            guard !watched.isEmpty else { return }
            var back: [String] = []
            for id in watched where (try await client.getAssetInfo(id: id).tags ?? []).contains(where: { $0.id == tagID }) {
                back.append(id)
            }
            if !back.isEmpty { _ = try await client.untagAssets(id: tagID, body: BulkIdsDto(ids: back)) }
        }
        pending.withLock { set in for id in ids { set.remove(key(tagID, id)) } }
    }
}
