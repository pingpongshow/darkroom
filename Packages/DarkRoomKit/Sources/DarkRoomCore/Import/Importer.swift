import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import ImmichAPI

/// One item to import: a photo or video, possibly paired (Live Photo motion, RAW+JPEG partner).
public struct ImportItem: Identifiable, Hashable, Sendable, Codable {
    public var id: String { file.path }
    public var file: URL
    /// Live Photo motion clip uploaded with (and linked to) this still.
    public var motion: URL?
    /// RAW+JPEG partner (stacked after upload).
    public var partner: URL?
    public var size: Int64
    public var created: Date
    public var checksum: String = ""
    public var alreadyInImmich = false
    public var isSelected = true
    public var kind: Kind

    public enum Kind: String, Sendable, Codable { case photo, video, raw, livePhoto }
}

public struct ImportOptions: Sendable, Codable, Equatable {
    public var albumID: String?
    public var newAlbumName: String?
    public var tags: [String] = []
    /// Stack RAW+JPEG pairs with the RAW on top (else the JPEG).
    public var rawOnTop = true
    public var archive = false
    public var favorite = false
    public init() {}
}

/// Finds media in files/folders, pairs Live Photos and RAW+JPEG, and checks which are already in Immich.
public enum ImportScanner {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "3gp", "mts", "m2ts"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "gif", "webp", "avif", "jxl", "bmp"]

    public static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || imageExtensions.contains(ext) || RenderEngine.rawExtensions.contains(ext)
    }

    /// Every media file under the given files/folders (recursive; hidden files and packages skipped).
    public static func files(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL { if isMedia(f) { out.append(f) } }
            } else if isMedia(url) {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Groups files into items: HEIC/JPG + MOV with the same Apple content identifier (or same name) → Live Photo;
    /// RAW + JPEG with the same name → pair.
    public static func items(from files: [URL]) async -> [ImportItem] {
        var used = Set<URL>()
        var items: [ImportItem] = []
        let byStem = Dictionary(grouping: files) { $0.deletingPathExtension().path.lowercased() }
        let videos = files.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
        var videoIDs: [String: URL] = [:]
        for v in videos { if let id = await videoContentIdentifier(v), videoIDs[id] == nil { videoIDs[id] = v } }
        for file in files where !used.contains(file) {
            let ext = file.pathExtension.lowercased()
            let stem = file.deletingPathExtension().path.lowercased()
            if videoExtensions.contains(ext) { continue }   // handled as motion or later as plain video
            var item = ImportItem(file: file, size: fileSize(file), created: captureDate(file), kind: RenderEngine.isRAW(file) ? .raw : .photo)
            if let id = stillContentIdentifier(file), let motion = videoIDs[id] {
                item.motion = motion; item.kind = .livePhoto; used.insert(motion)
            } else if let motion = byStem[stem]?.first(where: { videoExtensions.contains($0.pathExtension.lowercased()) }),
                      ["heic", "jpg", "jpeg"].contains(ext), await duration(motion) < 6 {
                item.motion = motion; item.kind = .livePhoto; used.insert(motion)
            }
            if RenderEngine.isRAW(file),
               let jpeg = byStem[stem]?.first(where: { ["jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) && $0 != file }),
               !used.contains(jpeg) {
                item.partner = jpeg; used.insert(jpeg)
            }
            used.insert(file)
            items.append(item)
        }
        // Remaining videos (not Live Photo motion), and JPEGs already claimed by RAW pairs are skipped.
        for file in files where !used.contains(file) && videoExtensions.contains(file.pathExtension.lowercased()) {
            items.append(ImportItem(file: file, size: fileSize(file), created: captureDate(file), kind: .video))
        }
        return items.sorted { $0.created < $1.created }
    }

    /// Marks items whose file is already in Immich (SHA-1 checksum, Immich's bulk upload check).
    public static func markExisting(_ items: inout [ImportItem], client: ImmichClient) async throws {
        for i in items.indices where items[i].checksum.isEmpty {
            items[i].checksum = (try? ImmichClient.sha1Base64(of: items[i].file)) ?? ""
        }
        for chunk in stride(from: 0, to: items.count, by: 500) {
            let slice = Array(items[chunk..<min(items.count, chunk + 500)])
            let response = try await client.checkBulkUpload(body: AssetBulkUploadCheckDto(assets: slice.map {
                AssetBulkUploadCheckItem(checksum: $0.checksum, id: $0.id)
            }))
            for result in response.results where result.action == .reject {
                if let i = items.firstIndex(where: { $0.id == result.id }) { items[i].alreadyInImmich = true; items[i].isSelected = false }
            }
        }
    }

    static func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }

    /// EXIF capture date, else the file's dates.
    public static func captureDate(_ url: URL) -> Date {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let offset = exif["OffsetTimeOriginal" as CFString] as? String, let tz = TimeZone(iso8601Offset: offset) { f.timeZone = tz }
            if let date = f.date(from: text) { return date }
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .now
    }

    /// Apple's Live Photo pairing id on a movie (QuickTime content identifier).
    static func videoContentIdentifier(_ url: URL) async -> String? {
        let items = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        for item in items where item.identifier == .quickTimeMetadataContentIdentifier {
            if let value = try? await item.load(.stringValue) { return value }
        }
        return nil
    }

    /// Apple's Live Photo pairing id on a still (MakerApple tag 17).
    static func stillContentIdentifier(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let apple = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return nil }
        return apple["17"] as? String
    }

    static func duration(_ url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }
}

private extension TimeZone {
    init?(iso8601Offset text: String) {
        let sign: Int = text.hasPrefix("-") ? -1 : 1
        let parts = text.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60))
    }
}

/// Uploads items (Live Photo motion first, then the linked still; RAW+JPEG stacked) and applies options.
/// The queue state is saved after every item, so an interrupted import resumes where it stopped.
public actor ImportQueue {
    public struct Job: Codable, Sendable, Identifiable {
        public var id = UUID()
        public var items: [ImportItem]
        public var options: ImportOptions
        public var done: [String: String] = [:]      // item id → asset id
        public var failed: [String: String] = [:]    // item id → error
        public var created = Date()
        public var remaining: [ImportItem] { items.filter { $0.isSelected && done[$0.id] == nil && failed[$0.id] == nil } }
    }

    public let client: ImmichClient
    let file: URL
    public private(set) var jobs: [Job]
    public private(set) var isPaused = false
    private var running = false

    public init(client: ImmichClient, file: URL) {
        self.client = client
        self.file = file
        jobs = (try? JSONDecoder().decode([Job].self, from: Data(contentsOf: file))) ?? []
    }

    public func add(_ items: [ImportItem], options: ImportOptions) -> UUID {
        let job = Job(items: items, options: options)
        jobs.append(job)
        persist()
        return job.id
    }

    public func setPaused(_ paused: Bool) { isPaused = paused }

    public var pendingCount: Int { jobs.reduce(0) { $0 + $1.remaining.count } }

    /// Processes every pending item; `progress` reports (done, total, current file name).
    public func run(progress: (@Sendable (Int, Int, String) -> Void)? = nil) async {
        guard !running else { return }
        running = true
        defer { running = false }
        for j in jobs.indices {
            var albumID = jobs[j].options.albumID
            if albumID == nil, let name = jobs[j].options.newAlbumName, !name.isEmpty,
               let album = try? await client.createAlbum(body: CreateAlbumDto(albumName: name)) {
                albumID = album.id
                jobs[j].options.albumID = album.id
                jobs[j].options.newAlbumName = nil
            }
            var tagIDs: [String] = []
            if !jobs[j].options.tags.isEmpty, let tags = try? await client.upsertTags(body: TagUpsertDto(tags: jobs[j].options.tags)) {
                tagIDs = tags.filter { jobs[j].options.tags.contains($0.value) }.map(\.id)
            }
            let total = jobs[j].items.filter(\.isSelected).count
            for item in jobs[j].remaining {
                while isPaused { try? await Task.sleep(for: .milliseconds(300)) }
                progress?(jobs[j].done.count + jobs[j].failed.count, total, item.file.lastPathComponent)
                do {
                    let id = try await upload(item, options: jobs[j].options)
                    var ids = [id]
                    if let partner = item.partner {
                        let partnerID = try await client.upload(file: partner, options: .init(fileCreatedAt: item.created,
                            fileModifiedAt: ImportScanner.modified(partner))).id
                        let ordered = jobs[j].options.rawOnTop ? [id, partnerID] : [partnerID, id]
                        _ = try? await client.createStack(body: StackCreateDto(assetIds: ordered))
                        ids.append(partnerID)
                    }
                    if let albumID { _ = try? await client.addAssetsToAlbum(id: albumID, body: BulkIdsDto(ids: ids)) }
                    if !tagIDs.isEmpty { _ = try? await client.bulkTagAssets(body: TagBulkAssetsDto(assetIds: ids, tagIds: tagIDs)) }
                    if jobs[j].options.archive || jobs[j].options.favorite {
                        try? await client.updateAssets(body: AssetBulkUpdateDto(ids: ids, isFavorite: jobs[j].options.favorite ? true : nil,
                                                                                visibility: jobs[j].options.archive ? .archive : nil))
                    }
                    jobs[j].done[item.id] = id
                } catch {
                    jobs[j].failed[item.id] = error.localizedDescription
                }
                persist()
            }
            progress?(jobs[j].done.count + jobs[j].failed.count, total, "")
        }
        jobs.removeAll { $0.remaining.isEmpty && $0.failed.isEmpty }
        persist()
    }

    /// Retries failed items.
    public func retryFailed() {
        for j in jobs.indices { jobs[j].failed = [:] }
        persist()
    }

    private func upload(_ item: ImportItem, options: ImportOptions) async throws -> String {
        var motionID: String?
        if let motion = item.motion {
            motionID = try await client.upload(file: motion, options: .init(fileCreatedAt: item.created,
                                                                            fileModifiedAt: ImportScanner.modified(motion), visibility: .hidden)).id
        }
        // Keep a sidecar .xmp next to the file, if there is one.
        let sidecar = [item.file.appendingPathExtension("xmp"), item.file.deletingPathExtension().appendingPathExtension("xmp")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        return try await client.upload(file: item.file, options: .init(fileCreatedAt: item.created, fileModifiedAt: ImportScanner.modified(item.file),
                                                                       livePhotoVideoID: motionID, sidecar: sidecar)).id
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(jobs).write(to: file, options: .atomic)
    }
}

extension ImportScanner {
    static func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now }
}
