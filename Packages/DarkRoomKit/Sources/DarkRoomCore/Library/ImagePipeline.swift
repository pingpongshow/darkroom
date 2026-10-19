import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import ImmichAPI

/// Fetches, caches and decodes Immich renditions (thumbnail / preview / full-size) for one user.
///
/// - Memory: decoded `CGImage`s in an `NSCache` (evicted under memory pressure).
/// - Disk: raw rendition bytes under `~/Library/Caches/DarkRoom/<account>/`, trimmed LRU to a
///   size limit. Keys include the asset's cache key (thumbhash), so edited assets refetch.
/// - Network: deduplicated, concurrency-limited requests.
public actor ImagePipeline {
    public struct Key: Hashable, Sendable {
        public var assetID: String
        public var size: AssetMediaSize
        public var cacheKey: String
        public init(assetID: String, size: AssetMediaSize, cacheKey: String) {
            self.assetID = assetID; self.size = size; self.cacheKey = cacheKey
        }
        var fileName: String {
            let digest = SHA256.hash(data: Data("\(assetID)|\(size.rawValue)|\(cacheKey)".utf8))
            return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        }
    }

    public let client: ImmichClient
    public let directory: URL
    public var diskLimitBytes: Int
    /// NSCache is thread-safe, so the grid can read it synchronously while configuring cells.
    nonisolated(unsafe) private let memory = NSCache<NSString, CGImageBox>()
    private var inFlight: [Key: Task<Data, Error>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maxConcurrent: Int

    public init(client: ImmichClient, accountID: UUID, diskLimitBytes: Int = 2 << 30, maxConcurrent: Int = 10,
                directory: URL? = nil) {
        self.client = client
        self.directory = directory ?? CacheLocation.account(accountID)
        self.diskLimitBytes = diskLimitBytes
        self.maxConcurrent = maxConcurrent
        memory.totalCostLimit = 512 << 20
    }

    /// Returns a decoded image no larger than `maxPixel` on its long edge (nil = full size).
    public func image(_ key: Key, maxPixel: Int? = nil) async throws -> CGImage {
        let memKey = "\(key.fileName)-\(maxPixel ?? 0)" as NSString
        if let cached = memory.object(forKey: memKey) { return cached.image }
        let data = try await data(key)
        try Task.checkCancellation()
        guard let image = Self.decode(data, maxPixel: maxPixel) else { throw ImmichError.decoding("Unreadable image", path: key.assetID) }
        memory.setObject(CGImageBox(image), forKey: memKey, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Memory-only lookup for synchronous drawing (nil if not cached yet).
    nonisolated public func cachedImage(_ key: Key, maxPixel: Int? = nil) -> CGImage? {
        memory.object(forKey: "\(key.fileName)-\(maxPixel ?? 0)" as NSString)?.image
    }

    /// Raw rendition bytes (disk cache or network).
    public func data(_ key: Key) async throws -> Data {
        let file = directory.appending(path: "\(key.size.rawValue)/\(key.fileName)")
        if let data = try? Data(contentsOf: file) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return data
        }
        if let task = inFlight[key] { return try await task.value }
        let task = Task<Data, Error> {
            await acquire()
            defer { Task { await self.release() } }
            try Task.checkCancellation()
            return try await client.thumbnail(assetID: key.assetID, size: key.size, edited: true)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// A person's face thumbnail (memory-cached; `version` is the person's updatedAt so changes refetch).
    public func faceImage(personID: String, version: String?, maxPixel: Int = 256) async throws -> CGImage {
        let memKey = "face-\(personID)-\(version ?? "")-\(maxPixel)" as NSString
        if let cached = memory.object(forKey: memKey) { return cached.image }
        await acquire()
        defer { release() }
        let data = try await client.personThumbnail(personID: personID)
        guard let image = Self.decode(data, maxPixel: maxPixel) else { throw ImmichError.decoding("Unreadable face", path: personID) }
        memory.setObject(CGImageBox(image), forKey: memKey, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Starts loading renditions ahead of display (e.g. next screenful, adjacent photos).
    public func prefetch(_ keys: [Key]) {
        for key in keys where inFlight[key] == nil {
            Task { _ = try? await self.data(key) }
        }
    }

    /// Drops cached renditions of an asset (after an edit or version change).
    /// NSCache can't drop one asset's entries, so decoded images are cleared; disk files are keyed by the
    /// asset's cache key, so a changed photo is fetched again anyway.
    public func invalidate(assetID _: String) {
        memory.removeAllObjects()
    }

    /// Trims the disk cache to its limit, oldest files first.
    public func trimDiskCache() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(URL, Int, Date)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.1 }
        guard total > diskLimitBytes else { return }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? fm.removeItem(at: url)
            total -= size
            if total <= diskLimitBytes * 9 / 10 { break }
        }
    }

    public func clearDiskCache() {
        try? FileManager.default.removeItem(at: directory)
        memory.removeAllObjects()
    }

    public var diskUsageBytes: Int {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    private func release() {
        running -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// Decodes (and optionally downsamples) image bytes with ImageIO.
    public static func decode(_ data: Data, maxPixel: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if let maxPixel {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

final class CGImageBox: NSObject, @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
