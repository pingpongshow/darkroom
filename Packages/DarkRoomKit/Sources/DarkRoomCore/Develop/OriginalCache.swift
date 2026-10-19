import Foundation
import ImmichAPI

/// Downloaded originals for editing (previews never need them), kept LRU under
/// `~/Library/Caches/DarkRoom/<account>/originals/`.
public actor OriginalCache {
    public let client: ImmichClient
    public let directory: URL
    public var limitBytes: Int
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(client: ImmichClient, accountID: UUID, limitBytes: Int = 8 << 30) {
        self.client = client
        directory = CacheLocation.account(accountID).appending(path: "originals")
        self.limitBytes = limitBytes
    }

    /// The original file for an asset (named by id + checksum, so a changed file is fetched again).
    public func file(for asset: AssetResponseDto, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let safeChecksum = asset.checksum.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").prefix(16)
        let ext = (asset.originalFileName as NSString).pathExtension
        let url = directory.appending(path: "\(asset.id)-\(safeChecksum).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        if let task = inFlight[asset.id] { return try await task.value }
        let task = Task { [client] in try await client.downloadOriginal(assetID: asset.id, to: url, progress: progress) }
        inFlight[asset.id] = task
        defer { inFlight[asset.id] = nil }
        let result = try await task.value
        trim()
        return result
    }

    public func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let info = files.compactMap { url -> (URL, Int, Date)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var total = 0
        for (url, size, _) in info {
            total += size
            if total > limitBytes { try? fm.removeItem(at: url) }
        }
    }
}
