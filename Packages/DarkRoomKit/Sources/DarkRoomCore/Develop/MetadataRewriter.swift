import Foundation
import ImmichAPI

/// Writes metadata into media files with the bundled ExifTool (lossless; no re-encoding).
public struct MetadataWriter: Sendable {
    public let exiftool: URL

    public init(exiftool: URL) { self.exiftool = exiftool }

    /// The metadata to write (whatever Immich currently has for the asset).
    public struct Fields: Sendable, Equatable {
        public var localDate: Date?           // wall-clock capture time
        public var timeZone: TimeZone?
        public var latitude: Double?
        public var longitude: Double?
        public var description: String?
        public var rating: Int?               // 0/nil = unrated
        public var tags: [String] = []        // "Parent/Child"
        /// New Apple Live Photo pairing id (written to both halves of a rewritten Live Photo).
        public var contentIdentifier: String?
        public init() {}
    }

    public static func fields(from asset: AssetResponseDto) -> Fields {
        var f = Fields()
        let exif = asset.exifInfo
        f.timeZone = exif?.timeZone.flatMap(TimeZone.init(identifier:))
        if let original = exif?.dateTimeOriginal.flatMap(ImmichDate.parse) {
            // dateTimeOriginal is an instant; express it as wall-clock time in its zone.
            let zone = f.timeZone ?? TimeZone(secondsFromGMT: 0)!
            f.localDate = original.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: original)))
        } else {
            f.localDate = ImmichDate.parse(asset.localDateTime)
        }
        f.latitude = exif?.latitude
        f.longitude = exif?.longitude
        f.description = exif?.description
        f.rating = exif?.rating
        f.tags = (asset.tags ?? []).map(\.value).filter { !$0.hasPrefix("Culling/") }
        return f
    }

    /// ExifTool arguments for the fields (image and video tags).
    public static func arguments(_ f: Fields, isVideo: Bool) -> [String] {
        var args = ["-overwrite_original", "-P", "-m", "-charset", "utf8", "-api", "QuickTimeUTC=1"]
        if let date = f.localDate {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(secondsFromGMT: 0)
            fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let wall = fmt.string(from: date)
            let zone = f.timeZone ?? .current
            let utcInstant = date.addingTimeInterval(-TimeInterval(zone.secondsFromGMT(for: date)))
            let seconds = zone.secondsFromGMT(for: utcInstant)
            let offset = String(format: "%@%02d:%02d", seconds >= 0 ? "+" : "-", abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
            if isVideo {
                // QuickTime dates are UTC; Keys:CreationDate carries the local time and offset.
                args += ["-QuickTime:CreateDate=\(wall)\(offset)", "-QuickTime:ModifyDate=\(wall)\(offset)",
                         "-Keys:CreationDate=\(wall)\(offset)", "-XMP:DateTimeOriginal=\(wall)\(offset)"]
            } else {
                args += ["-DateTimeOriginal=\(wall)", "-CreateDate=\(wall)", "-ModifyDate=\(wall)",
                         "-OffsetTimeOriginal=\(offset)", "-OffsetTimeDigitized=\(offset)", "-OffsetTime=\(offset)"]
            }
        }
        if let lat = f.latitude, let lon = f.longitude {
            args += ["-GPSLatitude=\(abs(lat))", "-GPSLatitudeRef=\(lat >= 0 ? "N" : "S")",
                     "-GPSLongitude=\(abs(lon))", "-GPSLongitudeRef=\(lon >= 0 ? "E" : "W")"]
            if isVideo { args += ["-Keys:GPSCoordinates=\(lat), \(lon)", "-UserData:GPSCoordinates=\(lat), \(lon)"] }
        }
        let description = f.description ?? ""
        args += isVideo ? ["-Keys:Description=\(description)", "-XMP-dc:Description=\(description)"]
                        : ["-ImageDescription=\(description)", "-XMP-dc:Description=\(description)", "-IPTC:Caption-Abstract=\(description)"]
        args += (f.rating ?? 0) > 0 ? ["-XMP:Rating=\(f.rating!)"] : ["-XMP:Rating="]
        if let id = f.contentIdentifier {
            args += isVideo ? ["-Keys:ContentIdentifier=\(id)"] : ["-MakerNotes:ContentIdentifier=\(id)"]
        }
        args += ["-XMP-dc:Subject=", "-XMP-lr:HierarchicalSubject="]
        for tag in f.tags {
            args += ["-XMP-dc:Subject+=\(tag.split(separator: "/").last.map(String.init) ?? tag)",
                     "-XMP-lr:HierarchicalSubject+=\(tag.replacingOccurrences(of: "/", with: "|"))"]
        }
        return args
    }

    /// Writes `fields` into `file` in place.
    public func write(_ fields: Fields, to file: URL, isVideo: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [exiftool.path] + Self.arguments(fields, isVideo: isVideo) + [file.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw RewriteError.exiftool(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public enum RewriteError: LocalizedError {
        case exiftool(String)
        case notOwner
        public var errorDescription: String? {
            switch self {
            case .exiftool(let m): "Couldn’t write metadata into the file: \(m)"
            case .notOwner: "Only your own photos can be rewritten."
            }
        }
    }
}

/// Makes metadata changes permanent in the files: the original (and its Mac version, if any) are rewritten
/// with Immich's current metadata, uploaded, and swapped in. The superseded file is hidden, not trashed,
/// so phones that backed it up never upload it again.
public struct MetadataRewriter: Sendable {
    public static let supersededKey = "darkroom.superseded"
    public let client: ImmichClient
    public let versions: VersionManager
    public let writer: MetadataWriter
    public let originals: OriginalCache

    public init(client: ImmichClient, versions: VersionManager, writer: MetadataWriter, originals: OriginalCache) {
        self.client = client
        self.versions = versions
        self.writer = writer
        self.originals = originals
    }

    public struct Result: Sendable {
        /// Old id → new id, for every asset that was replaced.
        public var replaced: [String: String]
        public var undo: UndoAction
    }

    /// Rewrites the files behind `assetID` (original, Live Photo motion and Mac version).
    public func rewrite(_ assetID: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let me = try await client.getMyUser().id
        let context = try await versions.context(for: assetID)
        guard context.original.ownerId == me else { throw MetadataWriter.RewriteError.notOwner }
        let original = context.original
        var replaced: [String: String] = [:]
        var undoSteps: [UndoAction] = []

        progress?("Writing metadata into \(original.originalFileName)…")
        let newOriginal = try await replace(original, hideNew: context.version != nil, progress: progress)
        replaced[original.id] = newOriginal.id
        undoSteps.append(newOriginal.undo)

        if let version = context.version, let record = try await versions.record(of: version.id) {
            progress?("Updating the edited version…")
            let newVersion = try await replace(version, hideNew: false, keepOld: false, progress: progress)
            replaced[version.id] = newVersion.id
            // Restack: new version on top of the new original (+ camera partners) and keep the record current.
            var stackID = await versions.stackID(primary: newVersion.id)
            if stackID == nil { stackID = await versions.stackID(primary: version.id) }
            if let stackID { try? await client.deleteStack(id: stackID) }
            _ = try await client.createStack(body: StackCreateDto(assetIds: [newVersion.id, newOriginal.id] + record.stackMembers))
            var newRecord = record
            newRecord.originalID = newOriginal.id
            newRecord.hidden.removeValue(forKey: original.id)
            newRecord.hidden[newOriginal.id] = record.hidden[original.id] ?? "timeline"
            _ = try await client.updateAssetMetadata(id: newVersion.id, body: AssetMetadataUpsertDto(items: [
                AssetMetadataUpsertItemDto(key: EditRecipe.metadataKey, value: try JSONValue(encoding: newRecord))]))
            _ = try await client.updateAssetMetadata(id: newOriginal.id, body: AssetMetadataUpsertDto(items: [
                AssetMetadataUpsertItemDto(key: VersionManager.versionKey, value: try JSONValue(encoding: VersionPointer(versionID: newVersion.id)))]))
            versions.registry.remove(versionID: version.id)
            versions.registry.add(.init(versionID: newVersion.id, originalID: newOriginal.id, hidden: newRecord.hidden))
            undoSteps.append(newVersion.undo)
        }

        let steps = undoSteps
        return Result(replaced: replaced, undo: UndoAction(name: "Write Metadata to File") {
            for step in steps.reversed() { try await step.run() }
        })
    }

    private struct Replacement { let id: String; let undo: UndoAction }

    /// Immich pairs stills and motion clips by Apple's content identifier when it extracts metadata, which can
    /// attach the new still to the old clip. Once extraction has run, set both pairs explicitly.
    private func relinkLivePhoto(newStill: String, newMotion: String, oldStill: String, oldMotion: String) async throws {
        for _ in 0..<60 {
            let still = try? await client.getAssetInfo(id: newStill)
            let motion = try? await client.getAssetInfo(id: newMotion)
            if still?.hasMetadata == true, motion?.hasMetadata == true { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .milliseconds(500))
        _ = try await client.updateAsset(id: newStill, body: UpdateAssetDto(livePhotoVideoId: newMotion))
        _ = try await client.updateAsset(id: oldStill, body: UpdateAssetDto(livePhotoVideoId: oldMotion))
        try await client.updateAssets(body: AssetBulkUpdateDto(ids: [newMotion, oldMotion], visibility: .hidden))
    }

    /// Uploads a metadata-updated copy of `asset` and swaps it in.
    /// - hideNew: the new file starts hidden (an original under a Mac version).
    /// - keepOld: hide the superseded file (originals) instead of trashing it (DarkRoom's own versions).
    private func replace(_ asset: AssetResponseDto, hideNew: Bool, keepOld: Bool = true,
                         progress: (@Sendable (String) -> Void)?) async throws -> Replacement {
        var fields = MetadataWriter.fields(from: asset)
        // A fresh pairing id so Immich links the new still only to the new motion clip.
        if asset.livePhotoVideoId != nil { fields.contentIdentifier = UUID().uuidString }
        let work = FileManager.default.temporaryDirectory.appending(path: "darkroom-rewrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Live Photo: rewrite the motion clip first and link the new still to it.
        var newMotionID: String?
        if let motionID = asset.livePhotoVideoId, let motion = try? await client.getAssetInfo(id: motionID) {
            let motionFile = work.appending(path: motion.originalFileName)
            try await client.downloadOriginal(assetID: motionID, to: motionFile)
            try writer.write(fields, to: motionFile, isVideo: true)
            let created = ImmichDate.parse(motion.fileCreatedAt) ?? .now
            newMotionID = try await client.upload(file: motionFile, options: .init(fileCreatedAt: created, fileModifiedAt: .now,
                                                                                    visibility: .hidden)).id
        }

        let source = try await originals.file(for: asset)
        let file = work.appending(path: asset.originalFileName)
        try FileManager.default.copyItem(at: source, to: file)
        try writer.write(fields, to: file, isVideo: asset.type == .video)
        progress?("Uploading \(asset.originalFileName)…")
        let created = fields.localDate.flatMap { local in
            fields.timeZone.map { local.addingTimeInterval(-TimeInterval($0.secondsFromGMT(for: local))) }
        } ?? ImmichDate.parse(asset.fileCreatedAt) ?? .now
        let upload = try await client.upload(file: file, options: .init(fileCreatedAt: created, fileModifiedAt: .now,
                                                                        livePhotoVideoID: newMotionID,
                                                                        visibility: hideNew ? .hidden : nil))
        let newID = upload.id
        try await versions.waitForAsset(newID)
        if let newMotionID, let oldMotionID = asset.livePhotoVideoId {
            try await relinkLivePhoto(newStill: newID, newMotion: newMotionID, oldStill: asset.id, oldMotion: oldMotionID)
        }

        // Carry albums, favourite, shared links and stack membership, then the API-level metadata and edits.
        let wasPrimary = await versions.stackID(primary: asset.id) != nil
        try await client.copyAsset(body: AssetCopyDto(albums: true, favorite: true, sharedLinks: true, sidecar: false,
                                                      sourceId: asset.id, stack: true, targetId: newID))
        try await versions.copyMetadata(from: asset, to: newID)
        if wasPrimary, let stackID = await versions.stackID(primary: asset.id) {
            _ = try? await client.updateStack(id: stackID, body: StackUpdateDto(primaryAssetId: newID))
        }
        if asset.isEdited, let edits = try? await client.getAssetEdits(id: asset.id).edits, !edits.isEmpty {
            _ = try? await client.editAsset(id: newID, body: AssetEditsCreateDto(edits: edits.map {
                AssetEditActionItemDto(action: $0.action, parameters: $0.parameters)
            }))
        }
        if asset.visibility == .archive && !hideNew {
            try await client.updateAssets(body: AssetBulkUpdateDto(ids: [newID], visibility: .archive))
        }

        // Retire the old file.
        let previousVisibility = asset.visibility
        if keepOld {
            try await client.updateAssets(body: AssetBulkUpdateDto(ids: [asset.id], visibility: .hidden))
            _ = try await client.updateAssetMetadata(id: asset.id, body: AssetMetadataUpsertDto(items: [
                AssetMetadataUpsertItemDto(key: Self.supersededKey, value: .object(["by": .string(newID)]))]))
        } else {
            try await client.deleteAssets(body: AssetBulkDeleteDto(force: false, ids: [asset.id]))
        }
        let oldID = asset.id, client = self.client
        let motion = newMotionID
        return Replacement(id: newID, undo: UndoAction(name: "Write Metadata to File") {
            if keepOld {
                try await client.updateAssets(body: AssetBulkUpdateDto(ids: [oldID], visibility: previousVisibility))
                try? await client.deleteAssetMetadata(id: oldID, key: Self.supersededKey)
            } else {
                _ = try await client.restoreAssets(body: BulkIdsDto(ids: [oldID]))
            }
            try await client.deleteAssets(body: AssetBulkDeleteDto(force: false, ids: [newID] + (motion.map { [$0] } ?? [])))
        })
    }
}
