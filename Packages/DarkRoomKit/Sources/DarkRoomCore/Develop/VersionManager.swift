import Foundation
import ImmichAPI
import ImageIO

/// What DarkRoom stores with a Mac version (asset metadata key `darkroom.recipe`).
public struct VersionRecord: Codable, Hashable, Sendable {
    public var recipe: EditRecipe
    public var originalID: String
    /// Assets hidden when the version was made, with their previous visibility (for revert / reconcile).
    public var hidden: [String: String]
    /// Other members of the original's stack (e.g. the camera's RAW+JPEG pair).
    public var stackMembers: [String]
    public var savedAt: Date
    public var app: String = "DarkRoom"
    /// The companion app that made this version ("Edit in…"), nil for Develop edits.
    public var editor: String?
}

/// Pointer stored on the original (asset metadata key `darkroom.version`).
public struct VersionPointer: Codable, Hashable, Sendable {
    public var versionID: String
}

/// Saves Develop edits to Immich, the way the plan describes:
/// - crop / 90° rotate / mirror only on a still → Immich's built-in edit (no new file);
/// - anything else → a Mac version: `<name>-edit.<ext>`, same capture date, metadata/albums copied,
///   stacked on top of the original, and the original set to `hidden` so nothing shows twice.
public struct VersionManager: Sendable {
    public static let versionKey = "darkroom.version"
    public let client: ImmichClient
    public let registry: VersionRegistry

    public init(client: ImmichClient, registry: VersionRegistry) {
        self.client = client
        self.registry = registry
    }

    // MARK: Looking up

    /// The editing context for any asset: the original, its current version (if any) and the saved recipe.
    public struct Context: Sendable {
        public var original: AssetResponseDto
        public var version: AssetResponseDto?
        public var recipe: EditRecipe
        public var builtInEdits: [AssetEditActionItemResponseDto]
    }

    public func context(for assetID: String) async throws -> Context {
        let asset = try await client.getAssetInfo(id: assetID)
        // Opened the version itself?
        if let record = try await record(of: asset.id) {
            let original = try await client.getAssetInfo(id: record.originalID)
            return Context(original: original, version: asset, recipe: record.recipe, builtInEdits: [])
        }
        // Opened an original that has a version?
        if let pointer = try await pointer(of: asset.id),
           let version = try? await client.getAssetInfo(id: pointer.versionID), !version.isTrashed,
           let record = try await record(of: version.id) {
            return Context(original: asset, version: version, recipe: record.recipe, builtInEdits: [])
        }
        let edits = asset.isEdited ? ((try? await client.getAssetEdits(id: asset.id))?.edits ?? []) : []
        return Context(original: asset, version: nil, recipe: Self.recipe(fromBuiltIn: edits, asset: asset), builtInEdits: edits)
    }

    /// RAW originals: starts their rendering from the look Immich shows for them (its preview), so opening the
    /// editor or saving doesn't change colours or brightness by itself. No-op for other files or without a preview.
    public func matchLibraryLook(original: AssetResponseDto, file: URL) async {
        guard RenderEngine.isRAW(file),
              let data = try? await client.thumbnail(assetID: original.id, size: .preview, edited: false),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let reference = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        await Task.detached(priority: .userInitiated) { RenderEngine.shared.matchLibraryLook(file, reference: reference) }.value
    }

    public func record(of id: String) async throws -> VersionRecord? {
        guard let item = try? await client.getAssetMetadataByKey(id: id, key: EditRecipe.metadataKey) else { return nil }
        return try? item.value.decodeISO(VersionRecord.self)
    }

    func pointer(of id: String) async throws -> VersionPointer? {
        guard let item = try? await client.getAssetMetadataByKey(id: id, key: Self.versionKey) else { return nil }
        return try? item.value.decodeISO(VersionPointer.self)
    }

    // MARK: Saving

    public enum Outcome: Sendable, Equatable {
        case unchanged
        case builtInEdit
        case version(String)
        case reverted
    }

    /// Saves `recipe` for `context`. `originalFile` is the downloaded original (needed for versions).
    public func save(_ recipe: EditRecipe, context: Context, originalFile: URL, isLivePhoto: Bool = false,
                     progress: (@Sendable (String) -> Void)? = nil) async throws -> Outcome {
        let original = context.original
        guard original.ownerId == (try await client.getMyUser().id) else { throw VersionError.notOwner }

        // Back to the original?
        if recipe.isIdentity {
            if context.version != nil { try await revert(context); return .reverted }
            if !context.builtInEdits.isEmpty { try await client.removeAssetEdits(id: original.id); return .reverted }
            return .unchanged
        }

        // Geometry-only on a regular still without a Mac version → Immich's built-in edit. Not for RAW: Immich renders
        // RAW with its own converter (and may not apply the edit), so a RAW crop becomes an edited version like
        // every other RAW edit.
        if recipe.isGeometryOnlyBuiltIn, context.version == nil, !isLivePhoto, original.type == .image,
           !RenderEngine.isRAW(originalFile) {
            let edits = Self.builtInEdits(recipe.geometry, asset: original)
            if edits.isEmpty { try await client.removeAssetEdits(id: original.id) }
            else { _ = try await client.editAsset(id: original.id, body: AssetEditsCreateDto(edits: edits)) }
            return .builtInEdit
        }

        // Mac version. Built-in geometry is folded into the recipe (the version is rendered from the original file).
        progress?("Rendering…")
        let work = FileManager.default.temporaryDirectory.appending(path: "darkroom-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let base = (original.originalFileName as NSString).deletingPathExtension
        let created = ImmichDate.parse(original.fileCreatedAt) ?? .now
        let versionID: String

        if original.type == .video {
            // Video: re-encoded (or lossless rotate/trim), same container.
            let output = work.appending(path: "\(base)-edit.\(originalFile.pathExtension.lowercased())")
            try await VideoRenderer().export(originalFile, recipe: recipe, to: output) { p in progress?("Rendering video… \(Int(p * 100))%") }
            progress?("Uploading…")
            versionID = try await client.upload(file: output, options: .init(filename: output.lastPathComponent,
                                                                             fileCreatedAt: created, fileModifiedAt: .now)).id
        } else {
            let (_, ext) = RenderEngine.outputType(for: originalFile, hdr: recipe.hdr)
            let output = work.appending(path: "\(base)-edit.\(ext)")
            await matchLibraryLook(original: original, file: originalFile)
            try RenderEngine.shared.export(original: originalFile, recipe: recipe, to: output)
            var motionID: String?
            if isLivePhoto, let originalMotion = original.livePhotoVideoId {
                // Live Photo: the motion clip gets the same edit, and both halves a fresh pairing id.
                progress?("Rendering motion…")
                let motionInfo = try await client.getAssetInfo(id: originalMotion)
                let motionFile = try await client.downloadOriginal(assetID: originalMotion, to: work.appending(path: motionInfo.originalFileName))
                let motionOut = work.appending(path: "\(base)-edit.mov")
                try await VideoRenderer().export(motionFile, recipe: recipe.motionSafe, to: motionOut)
                if let exiftool = RenderEngine.exiftoolURL {
                    var fields = MetadataWriter.Fields()
                    fields = MetadataWriter.fields(from: original)
                    fields.contentIdentifier = UUID().uuidString
                    let writer = MetadataWriter(exiftool: exiftool)
                    try writer.write(fields, to: output, isVideo: false)
                    try writer.write(fields, to: motionOut, isVideo: true)
                }
                progress?("Uploading…")
                motionID = try await client.upload(file: motionOut, options: .init(filename: motionOut.lastPathComponent, fileCreatedAt: created,
                                                                                    fileModifiedAt: .now, visibility: .hidden)).id
            }
            progress?("Uploading…")
            versionID = try await client.upload(file: output, options: .init(filename: output.lastPathComponent, fileCreatedAt: created,
                                                                             fileModifiedAt: .now, livePhotoVideoID: motionID)).id
            if let motionID, let originalMotion = original.livePhotoVideoId {
                try await waitForAsset(versionID)
                try await relinkLivePhoto(newStill: versionID, newMotion: motionID, oldStill: original.id, oldMotion: originalMotion)
            }
        }
        try await waitForAsset(versionID)

        return try await link(versionID, recipe: recipe, editor: nil, context: context, progress: progress)
    }

    /// Edit in…: uploads a companion app's result (in the original's format) as the Mac version.
    public func saveExternal(_ result: URL, context: Context, originalFile: URL, editor: String,
                             progress: (@Sendable (String) -> Void)? = nil) async throws -> Outcome {
        let original = context.original
        guard original.ownerId == (try await client.getMyUser().id) else { throw VersionError.notOwner }
        let work = FileManager.default.temporaryDirectory.appending(path: "darkroom-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let base = (original.originalFileName as NSString).deletingPathExtension
        let (_, ext) = RenderEngine.outputType(for: originalFile)
        let output = work.appending(path: "\(base)-edit.\(ext)")
        try RenderEngine.shared.transcode(result, like: originalFile, to: output)
        progress?("Uploading…")
        let created = ImmichDate.parse(original.fileCreatedAt) ?? .now
        let versionID = try await client.upload(file: output, options: .init(filename: output.lastPathComponent,
                                                                             fileCreatedAt: created, fileModifiedAt: .now)).id
        try await waitForAsset(versionID)
        return try await link(versionID, recipe: EditRecipe(), editor: editor, context: context, progress: progress)
    }

    /// Copies metadata to a freshly uploaded version, stacks it on top, hides the original(s) and records it.
    func link(_ versionID: String, recipe: EditRecipe, editor: String?, context: Context,
              progress: (@Sendable (String) -> Void)?) async throws -> Outcome {
        let original = context.original
        progress?("Linking…")
        // Carry albums, favourite and shared links (Immich's own copy), then the rest of the metadata.
        try await client.copyAsset(body: AssetCopyDto(albums: true, favorite: true, sharedLinks: true, sidecar: false,
                                                      sourceId: original.id, stack: false, targetId: versionID))
        try await copyMetadata(from: original, to: versionID)

        // Stack: version on top of the original (and its RAW+JPEG partners).
        var members: [String] = []
        if let old = context.version, let record = try await record(of: old.id) {
            members = record.stackMembers
            if let stackID = await stackID(primary: old.id) { try? await client.deleteStack(id: stackID) }
        } else if let stack = original.stack {
            let full = try await client.getStack(id: stack.id)
            members = full.assets.map(\.id).filter { $0 != original.id }
            try await client.deleteStack(id: stack.id)
        }
        _ = try await client.createStack(body: StackCreateDto(assetIds: [versionID, original.id] + members))

        // Hide the original(s) so albums, search, people, memories and the map show only the version.
        var hidden: [String: String] = [:]
        for id in [original.id] + members {
            let info = id == original.id ? original : try await client.getAssetInfo(id: id)
            let previousRecord = context.version != nil ? try await record(of: context.version!.id) : nil
            let before = info.visibility == .hidden
                ? (previousRecord?.hidden[id] ?? registry.previousVisibility(of: id) ?? "timeline")
                : info.visibility.rawValue
            hidden[id] = before
        }
        try await client.updateAssets(body: AssetBulkUpdateDto(ids: Array(hidden.keys), visibility: .hidden))

        // Remember the recipe on the version and point the original at it.
        let record = VersionRecord(recipe: recipe, originalID: original.id, hidden: hidden, stackMembers: members, savedAt: .now, editor: editor)
        _ = try await client.updateAssetMetadata(id: versionID, body: AssetMetadataUpsertDto(items: [
            AssetMetadataUpsertItemDto(key: EditRecipe.metadataKey, value: try JSONValue(encoding: record))]))
        _ = try await client.updateAssetMetadata(id: original.id, body: AssetMetadataUpsertDto(items: [
            AssetMetadataUpsertItemDto(key: Self.versionKey, value: try JSONValue(encoding: VersionPointer(versionID: versionID)))]))
        if !context.builtInEdits.isEmpty { try? await client.removeAssetEdits(id: original.id) }

        // Only ever original + latest version: the previous Mac version goes to Immich's trash.
        // Update the registry first so the reconciler never treats this deliberate trash as an outside removal.
        registry.add(VersionRegistry.Entry(versionID: versionID, originalID: original.id, hidden: hidden))
        if let old = context.version {
            registry.remove(versionID: old.id)
            try? await client.deleteAssets(body: AssetBulkDeleteDto(force: false, ids: [old.id] + (old.livePhotoVideoId.map { [$0] } ?? [])))
        }
        return .version(versionID)
    }

    /// Revert to original: restore visibility, unstack (keeping the camera pair stacked), trash the version.
    public func revert(_ context: Context) async throws {
        guard let version = context.version, let record = try await record(of: version.id) else { return }
        for (id, visibility) in record.hidden {
            try await client.updateAssets(body: AssetBulkUpdateDto(ids: [id], visibility: AssetVisibility(rawValue: visibility)))
        }
        if let stackID = await stackID(primary: version.id) { try? await client.deleteStack(id: stackID) }
        if !record.stackMembers.isEmpty {
            _ = try? await client.createStack(body: StackCreateDto(assetIds: [record.originalID] + record.stackMembers))
        }
        registry.remove(versionID: version.id)
        try await client.deleteAssets(body: AssetBulkDeleteDto(force: false, ids: [version.id] + (version.livePhotoVideoId.map { [$0] } ?? [])))
        try? await client.deleteAssetMetadata(id: record.originalID, key: Self.versionKey)
    }

    /// Copies description, rating, date/time zone, location and tags (things `PUT /assets/copy` doesn't).
    func copyMetadata(from original: AssetResponseDto, to id: String) async throws {
        let exif = original.exifInfo
        try await client.updateAssets(body: AssetBulkUpdateDto(
            dateTimeOriginal: exif?.dateTimeOriginal ?? original.fileCreatedAt,
            description: exif?.description,
            ids: [id],
            latitude: exif?.latitude, longitude: exif?.longitude,
            timeZone: exif?.timeZone,
            visibility: original.visibility == .archive ? .archive : nil))
        if let rating = exif?.rating, rating > 0 { try await AssetActions.rate(client, [id], rating) }
        let tags = (original.tags ?? []).map(\.id)
        if !tags.isEmpty { _ = try await client.bulkTagAssets(body: TagBulkAssetsDto(assetIds: [id], tagIds: tags)) }
    }

    /// Immich only reports timeline-visible stack members on assets, so stacks whose other members are hidden
    /// are found through their primary asset.
    func stackID(primary id: String) async -> String? {
        if let stack = try? await client.getAssetInfo(id: id).stack { return stack.id }
        return (try? await client.searchStacks(primaryAssetId: id))?.first?.id
    }

    /// Immich pairs stills and motion clips by Apple's content identifier during metadata extraction, which can
    /// attach a new still to an old clip. Once extraction has run, both pairs are set explicitly.
    func relinkLivePhoto(newStill: String, newMotion: String, oldStill: String, oldMotion: String) async throws {
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

    func waitForAsset(_ id: String) async throws {
        for _ in 0..<20 {
            if (try? await client.getAssetInfo(id: id)) != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Waits (up to `timeout`) until Immich has generated an asset's thumbnails (new ones, when `replacing` is the
    /// thumbhash from before an edit), so the photo can be shown straight away. Large files such as the 16-bit
    /// TIFFs saved for RAW edits, or RAW originals re-rendered for a crop, take a few seconds.
    public func waitForThumbnails(_ id: String, replacing old: String? = nil, timeout: Duration = .seconds(60)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let asset = try? await client.getAssetInfo(id: id), let hash = asset.thumbhash, hash != old { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Built-in edits (crop / rotate / mirror)

    /// Immich applies crop first (in the original's pixel space), then rotation, then mirroring.
    static func builtInEdits(_ g: EditRecipe.Geometry, asset: AssetResponseDto) -> [AssetEditActionItemDto] {
        var edits: [AssetEditActionItemDto] = []
        let turns = ((g.quarterTurns % 4) + 4) % 4
        if let crop = g.crop, crop != .full {
            let w = Double(asset.width ?? asset.exifInfo?.exifImageWidth ?? 0)
            let h = Double(asset.height ?? asset.exifInfo?.exifImageHeight ?? 0)
            if w > 0, h > 0 {
                let r = Self.cropInOriginalSpace(crop, turns: turns, flipH: g.flipHorizontal, flipV: g.flipVertical)
                edits.append(AssetEditActionItemDto(action: .crop, parameters: .object([
                    "x": .number((r.x * w).rounded()), "y": .number((r.y * h).rounded()),
                    "width": .number(max(1, (r.width * w).rounded())), "height": .number(max(1, (r.height * h).rounded()))])))
            }
        }
        if turns != 0 { edits.append(AssetEditActionItemDto(action: .rotate, parameters: .object(["angle": .number(Double(turns * 90))]))) }
        if g.flipHorizontal { edits.append(AssetEditActionItemDto(action: .mirror, parameters: .object(["axis": .string("horizontal")]))) }
        if g.flipVertical { edits.append(AssetEditActionItemDto(action: .mirror, parameters: .object(["axis": .string("vertical")]))) }
        return edits
    }

    /// Maps a crop defined after rotation (clockwise quarter turns) and mirroring back to the original image.
    public static func cropInOriginalSpace(_ c: EditRecipe.CropRect, turns: Int, flipH: Bool, flipV: Bool) -> EditRecipe.CropRect {
        var r = c
        if flipV { r.y = 1 - r.y - r.height }
        if flipH { r.x = 1 - r.x - r.width }
        for _ in 0..<turns {
            // Undo one clockwise turn: rotated (x, y) ← original (u, v) with x = 1 - v, y = u.
            r = .init(x: r.y, y: 1 - r.x - r.width, width: r.height, height: r.width)
        }
        return r
    }

    /// The inverse: a crop in the original's space shown after rotation and mirroring.
    public static func cropInDisplaySpace(_ c: EditRecipe.CropRect, turns: Int, flipH: Bool, flipV: Bool) -> EditRecipe.CropRect {
        var r = c
        for _ in 0..<turns {
            r = .init(x: 1 - r.y - r.height, y: r.x, width: r.height, height: r.width)
        }
        if flipH { r.x = 1 - r.x - r.width }
        if flipV { r.y = 1 - r.y - r.height }
        return r
    }

    /// Reads Immich's built-in edits back into a recipe (so DarkRoom shows crops made in Immich web).
    static func recipe(fromBuiltIn edits: [AssetEditActionItemResponseDto], asset: AssetResponseDto) -> EditRecipe {
        var recipe = EditRecipe()
        var turns = 0
        var originalCrop: EditRecipe.CropRect?
        for edit in edits {
            guard case .object(let p) = edit.parameters else { continue }
            switch edit.action {
            case .rotate:
                if case .number(let angle) = p["angle"] { turns = Int(angle / 90) % 4; recipe.geometry.quarterTurns = turns }
            case .mirror:
                if case .string(let axis) = p["axis"] {
                    if axis == "horizontal" { recipe.geometry.flipHorizontal = true } else { recipe.geometry.flipVertical = true }
                }
            case .crop:
                let w = Double(asset.width ?? 0), h = Double(asset.height ?? 0)
                if w > 0, h > 0, case .number(let x) = p["x"], case .number(let y) = p["y"],
                   case .number(let cw) = p["width"], case .number(let ch) = p["height"] {
                    originalCrop = .init(x: x / w, y: y / h, width: cw / w, height: ch / h)
                }
            default: break
            }
        }
        if let originalCrop {
            recipe.geometry.crop = cropInDisplaySpace(originalCrop, turns: turns, flipH: recipe.geometry.flipHorizontal,
                                                      flipV: recipe.geometry.flipVertical)
        }
        return recipe
    }

    public enum VersionError: LocalizedError {
        case notOwner
        case livePhotoNotYetSupported
        public var errorDescription: String? {
            switch self {
            case .notOwner: "Only your own photos can be edited."
            case .livePhotoNotYetSupported: "Adjustments on Live Photos need the still and motion edited together (coming next). Crop and rotation are saved."
            }
        }
    }
}

// MARK: Registry and reconciler

/// Local list of versions this Mac made, per user (the reconciler's starting point).
public final class VersionRegistry: @unchecked Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var versionID: String
        public var originalID: String
        public var hidden: [String: String]
    }

    private let file: URL
    private let lock = NSLock()
    private var entries: [Entry]

    public init(file: URL) {
        self.file = file
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
    }

    public var all: [Entry] { lock.withLock { entries } }

    public func add(_ entry: Entry) {
        lock.withLock { entries.removeAll { $0.originalID == entry.originalID }; entries.append(entry) }
        persist()
    }

    public func remove(versionID: String) {
        lock.withLock { entries.removeAll { $0.versionID == versionID } }
        persist()
    }

    func previousVisibility(of id: String) -> String? {
        lock.withLock { entries.compactMap { $0.hidden[id] }.first }
    }

    private func persist() {
        let snapshot = lock.withLock { entries }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
}

/// Keeps originals and versions consistent even when things change outside DarkRoom.
public struct Reconciler: Sendable {
    public let client: ImmichClient
    public let registry: VersionRegistry

    public init(client: ImmichClient, registry: VersionRegistry) {
        self.client = client
        self.registry = registry
    }

    public enum Action: Sendable, Equatable {
        case unhidOriginal(String)      // the version was trashed/deleted elsewhere
        case rehidOriginal(String)      // something un-hid the original
    }

    /// Checks every version this Mac knows about. Returns what it fixed (for the Activity log).
    @discardableResult
    public func run() async -> [Action] {
        var actions: [Action] = []
        for entry in registry.all {
            let version = try? await client.getAssetInfo(id: entry.versionID)
            if version == nil || version?.isTrashed == true {
                for (id, visibility) in entry.hidden {
                    // Only originals that are still hidden need restoring.
                    guard let info = try? await client.getAssetInfo(id: id), info.visibility == .hidden else { continue }
                    try? await client.updateAssets(body: AssetBulkUpdateDto(ids: [id], visibility: AssetVisibility(rawValue: visibility)))
                    actions.append(.unhidOriginal(id))
                }
                try? await client.deleteAssetMetadata(id: entry.originalID, key: VersionManager.versionKey)
                registry.remove(versionID: entry.versionID)
                continue
            }
            for id in entry.hidden.keys {
                guard let info = try? await client.getAssetInfo(id: id), !info.isTrashed else { continue }
                if info.visibility != .hidden {
                    try? await client.updateAssets(body: AssetBulkUpdateDto(ids: [id], visibility: .hidden))
                    actions.append(.rehidOriginal(id))
                }
            }
        }
        return actions
    }
}

extension JSONValue {
    init<T: Encodable>(encoding value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    func decodeISO<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }
}
