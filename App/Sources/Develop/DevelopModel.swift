import SwiftUI
import CoreImage
import ImmichAPI
import DarkRoomCore

/// State for the Develop module (D): the photo being edited, its recipe, live previews and saving.
@MainActor
final class DevelopModel: ObservableObject {
    let library: LibraryModel
    let versions: VersionManager
    let originals: OriginalCache
    private let engine = RenderEngine.shared

    @Published private(set) var assetID: String?
    @Published private(set) var context: VersionManager.Context?
    @Published var recipe = EditRecipe() { didSet { if recipe != oldValue { scheduleRender(); dirty = true } } }
    @Published private(set) var preview: CGImage?
    @Published private(set) var histogram: Histogram?
    @Published private(set) var status: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    @Published var showBefore = false { didSet { scheduleRender() } }
    @Published var cropping = false { didSet { scheduleRender() } }
    @Published var eyedropper = false
    @Published private(set) var dirty = false
    /// The RAW file's as-shot white balance, for the Kelvin slider.
    @Published private(set) var rawNeutral: (kelvin: Double, tint: Double)?
    @Published private(set) var isRAW = false
    @Published private(set) var canEdit = true

    /// Size the preview is rendered at (long edge, pixels); set from the view's size.
    var previewPixels: CGFloat = 1600 { didSet { if abs(previewPixels - oldValue) > 64 { scheduleRender() } } }

    private var originalFile: URL?
    private var base: CIImage?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    private var undoStack: [EditRecipe] = []
    private var redoStack: [EditRecipe] = []
    private var committed = EditRecipe()
    static var clipboard: (recipe: EditRecipe, panels: Set<DevelopPanel>)?

    init(library: LibraryModel) {
        self.library = library
        let registryFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DarkRoom/\(library.session.account.id.uuidString)/versions.json")
        versions = VersionManager(client: library.client, registry: VersionRegistry(file: registryFile))
        originals = OriginalCache(client: library.client, accountID: library.session.account.id)
    }

    // MARK: Opening

    func open(_ assetID: String) async {
        guard assetID != self.assetID else { return }
        if dirty { await save() }
        self.assetID = assetID
        context = nil; preview = nil; base = nil; originalFile = nil; error = nil; histogram = nil
        undoStack = []; redoStack = []
        isLoading = true
        defer { isLoading = false }
        do {
            let context = try await versions.context(for: assetID)
            guard self.assetID == assetID else { return }
            self.context = context
            canEdit = context.original.ownerId == library.session.account.userID
            status = "Downloading original…"
            let file = try await originals.file(for: context.original)
            guard self.assetID == assetID else { return }
            originalFile = file
            isRAW = RenderEngine.isRAW(file)
            rawNeutral = engine.rawNeutral(file)
            status = canEdit ? nil : "View only: only your own photos can be edited"
            committed = context.recipe
            recipe = context.recipe
            dirty = false
            scheduleRender()
        } catch {
            self.error = "Couldn’t open for editing: \(error.localizedDescription)"
            status = nil
        }
    }

    // MARK: Rendering

    func scheduleRender() {
        guard let file = originalFile else { return }
        renderGeneration += 1
        let generation = renderGeneration
        var recipe = showBefore ? EditRecipe() : recipe
        if cropping { recipe.geometry.crop = nil; recipe.geometry.straighten = showBefore ? 0 : recipe.geometry.straighten }
        let maxPixel = previewPixels
        let isRAW = self.isRAW
        let engine = self.engine
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            // Coalesce rapid slider changes.
            try? await Task.sleep(for: .milliseconds(12))
            guard !Task.isCancelled else { return }
            let result: Result<(CGImage, Histogram?), Error>? = await Task.detached(priority: .userInitiated) {
                do {
                    // RAW is decoded at a reduced scale for previews; full size on export.
                    let scaleFactor = isRAW ? max(0.25, min(1, Double(maxPixel) / 2500)) : 1
                    let base = try engine.base(file, recipe: recipe, draft: false, scaleFactor: scaleFactor)
                    let image = engine.render(base, recipe: recipe, isRAW: isRAW, maxPixel: maxPixel, neutralKey: file.path)
                    guard let cg = engine.cgImage(image) else { return nil }
                    return .success((cg, Histogram.compute(cg)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled, generation == self.renderGeneration, let result else { return }
            switch result {
            case .success(let (cg, histogram)):
                self.preview = cg
                self.histogram = histogram
            case .failure(let error):
                self.error = "Couldn’t render: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Editing history

    /// Call when a slider drag ends (or any discrete change) to make one undo step.
    func commit() {
        guard recipe != committed else { return }
        undoStack.append(committed)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        committed = recipe
    }

    func set(_ change: (inout EditRecipe) -> Void) {
        var r = recipe
        change(&r)
        recipe = r
        commit()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        committed = previous
        recipe = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        committed = next
        recipe = next
    }

    func reset(_ panel: DevelopPanel? = nil) {
        set { r in
            if let panel { panel.reset(&r) } else {
                let snapshots = r.snapshots
                r = EditRecipe()
                r.snapshots = snapshots
            }
        }
    }

    // MARK: Copy / paste / sync

    func copySettings(_ panels: Set<DevelopPanel> = Set(DevelopPanel.allCases).subtracting([.geometry])) {
        Self.clipboard = (recipe, panels)
        library.flash("Copied \(panels.count == DevelopPanel.allCases.count - 1 ? "all settings" : "\(panels.count) panels")")
    }

    func pasteSettings() {
        guard let clip = Self.clipboard else { return }
        set { r in for panel in clip.panels { panel.copy(from: clip.recipe, to: &r) } }
    }

    /// Applies this photo's settings (chosen panels) to the other selected photos and saves them in the background.
    func sync(to ids: [String], panels: Set<DevelopPanel>) {
        let source = recipe
        let others = ids.filter { $0 != assetID }
        guard !others.isEmpty else { return }
        Task {
            var done = 0
            for id in others {
                library.statusMessage = "Syncing \(done + 1) of \(others.count)…"
                do {
                    let context = try await versions.context(for: id)
                    var target = context.recipe
                    for panel in panels { panel.copy(from: source, to: &target) }
                    let file = try await originals.file(for: context.original)
                    _ = try await versions.save(target, context: context, originalFile: file)
                    done += 1
                } catch {
                    library.flash("Sync failed for one photo: \(error.localizedDescription)", isError: true)
                }
            }
            library.flash("Synced settings to \(done) photo\(done == 1 ? "" : "s")")
            await library.timeline.reload()
        }
    }

    // MARK: Auto

    /// Auto tone from the current preview's luminance distribution.
    func autoTone() {
        guard let histogram else { return }
        let bins = histogram.luma
        let total = bins.reduce(0, +)
        guard total > 0 else { return }
        func percentile(_ p: Float) -> Float {
            var acc: Float = 0
            for (i, v) in bins.enumerated() { acc += v; if acc / total >= p { return Float(i) / 255 } }
            return 1
        }
        let low = percentile(0.005), high = percentile(0.995), mid = percentile(0.5)
        set { r in
            r.exposure = Double(max(-2, min(2, log2(0.42 / max(mid, 0.02)))))
            r.whites = Double(max(-60, min(60, (0.97 - high) * 250)))
            r.blacks = Double(max(-60, min(60, (0.03 - low) * -250)))
            r.highlights = high > 0.98 ? -35 : 0
            r.shadows = low < 0.02 ? 25 : 0
            r.contrast = 10
            r.vibrance = max(r.vibrance, 10)
        }
    }

    /// Auto white balance (grey world on the preview).
    func autoWhiteBalance() {
        guard let preview else { return }
        let avg = Self.averageColor(preview)
        let warmth = (avg.z - avg.x)       // positive = image too blue → warm it
        let magenta = avg.y - (avg.x + avg.z) / 2
        set { r in
            r.whiteBalance = .custom
            r.neutralPoint = nil
            if let neutral = rawNeutral {
                r.temperature = max(2000, min(50000, neutral.kelvin * Double(1 + warmth * 1.2)))
                r.tint = neutral.tint + Double(magenta * 150)
            } else {
                r.temperature = Double(max(-100, min(100, warmth * 160)))
                r.tint = Double(max(-100, min(100, magenta * 160)))
            }
        }
    }

    /// Eyedropper: a click on the preview (normalised, top-left origin) picks the neutral point.
    func pickNeutral(at point: CGPoint) {
        eyedropper = false
        let mapped = Self.displayToBase(point, geometry: recipe.geometry)
        set { r in
            r.whiteBalance = .custom
            r.neutralPoint = [Double(mapped.x), Double(mapped.y)]
            r.temperature = 0; r.tint = 0
        }
    }

    /// Maps a point on the edited (rotated, mirrored, cropped) preview back to the unedited image.
    static func displayToBase(_ p: CGPoint, geometry g: EditRecipe.Geometry) -> CGPoint {
        var x = Double(p.x), y = Double(p.y)
        if let crop = g.crop { x = crop.x + x * crop.width; y = crop.y + y * crop.height }
        let rect = VersionManager.cropInOriginalSpace(.init(x: x, y: y, width: 0, height: 0), turns: ((g.quarterTurns % 4) + 4) % 4,
                                                      flipH: g.flipHorizontal, flipV: g.flipVertical)
        return CGPoint(x: rect.x, y: rect.y)
    }

    static func averageColor(_ image: CGImage) -> SIMD3<Float> {
        let ci = CIImage(cgImage: image)
        let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [Float](repeating: 0, count: 4)
        RenderEngine.shared.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return SIMD3(px[0], px[1], px[2])
    }

    // MARK: Snapshots

    func addSnapshot(named name: String) {
        set { r in r.snapshots.append(EditRecipe.Snapshot(name: name, recipe: r)) }
    }

    func apply(_ snapshot: EditRecipe.Snapshot) {
        guard var restored = try? JSONDecoder().decode(EditRecipe.self, from: snapshot.recipe) else { return }
        restored.snapshots = recipe.snapshots
        set { $0 = restored }
    }

    // MARK: Saving

    /// Saves to Immich (built-in edit, Mac version, or revert). Called on Done, when switching photos and on leaving Develop.
    func save() async {
        guard dirty, canEdit, let context, let originalFile else { dirty = false; return }
        isSaving = true
        defer { isSaving = false }
        let recipe = self.recipe
        do {
            let outcome = try await versions.save(recipe, context: context, originalFile: originalFile,
                                                  isLivePhoto: context.original.livePhotoVideoId != nil) { [weak self] message in
                Task { @MainActor in self?.status = message }
            }
            dirty = false
            status = nil
            switch outcome {
            case .unchanged: break
            case .builtInEdit: library.flash("Saved crop/rotation to Immich")
            case .version(let id):
                library.flash("Saved edited version")
                if library.focusedAssetID == context.version?.id || library.focusedAssetID == context.original.id {
                    library.focusedAssetID = id
                }
                self.assetID = id
                self.context = try? await versions.context(for: id)
            case .reverted: library.flash("Reverted to original")
            }
            await library.timeline.reload()
            library.detailsRevision += 1
            await library.pipeline.invalidate(assetID: context.original.id)
        } catch {
            self.error = "Couldn’t save: \(error.localizedDescription)"
            status = nil
        }
    }

    func revertToOriginal() {
        set { r in let s = r.snapshots; r = EditRecipe(); r.snapshots = s }
        Task { await save() }
    }
}

/// Develop panels (for reset, copy/paste and sync).
enum DevelopPanel: String, CaseIterable, Identifiable {
    case profile = "Profile & RAW", whiteBalance = "White Balance", tone = "Tone", presence = "Presence"
    case curve = "Tone Curve", mixer = "Colour Mixer", grading = "Colour Grading", detail = "Detail", effects = "Effects"
    case geometry = "Crop & Geometry"
    var id: String { rawValue }

    func copy(from source: EditRecipe, to r: inout EditRecipe) {
        switch self {
        case .profile: r.profile = source.profile; r.profileAmount = source.profileAmount; r.raw = source.raw
        case .whiteBalance: r.whiteBalance = source.whiteBalance; r.temperature = source.temperature; r.tint = source.tint
            r.neutralPoint = source.neutralPoint
        case .tone: r.exposure = source.exposure; r.contrast = source.contrast; r.highlights = source.highlights
            r.shadows = source.shadows; r.whites = source.whites; r.blacks = source.blacks
        case .presence: r.texture = source.texture; r.clarity = source.clarity; r.dehaze = source.dehaze
            r.vibrance = source.vibrance; r.saturation = source.saturation
        case .curve: r.parametric = source.parametric; r.curveRGB = source.curveRGB; r.curveRed = source.curveRed
            r.curveGreen = source.curveGreen; r.curveBlue = source.curveBlue
        case .mixer: r.hsl = source.hsl; r.monochrome = source.monochrome; r.bwMix = source.bwMix
        case .grading: r.grading = source.grading
        case .detail: r.sharpenAmount = source.sharpenAmount; r.sharpenRadius = source.sharpenRadius
            r.sharpenDetail = source.sharpenDetail; r.sharpenMasking = source.sharpenMasking
            r.noiseLuminance = source.noiseLuminance; r.noiseColor = source.noiseColor
        case .effects: r.vignetteAmount = source.vignetteAmount; r.vignetteMidpoint = source.vignetteMidpoint
            r.vignetteRoundness = source.vignetteRoundness; r.vignetteFeather = source.vignetteFeather
            r.grainAmount = source.grainAmount; r.grainSize = source.grainSize; r.grainRoughness = source.grainRoughness
        case .geometry: r.geometry = source.geometry
        }
    }

    func reset(_ r: inout EditRecipe) { copy(from: EditRecipe(), to: &r) }
}
