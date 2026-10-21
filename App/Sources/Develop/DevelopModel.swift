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
    @Published var cropping = false {
        didSet {
            if cropping, !oldValue { cropDraft = recipe.geometry.crop ?? .full }
            scheduleRender()
        }
    }
    /// The crop box being drawn in Crop mode (applied by Apply, Save, or Save when leaving the editor).
    @Published var cropDraft: EditRecipe.CropRect = .full
    @Published var eyedropper = false
    @Published private(set) var dirty = false
    /// The RAW file's as-shot white balance, for the Kelvin slider.
    @Published private(set) var rawNeutral: (kelvin: Double, tint: Double)?
    @Published private(set) var isRAW = false
    @Published private(set) var canEdit = true
    /// Preset being hovered in the Presets panel (previewed live, not applied).
    @Published var hoverPreset: Preset? { didSet { if hoverPreset != oldValue { scheduleRender() } } }
    /// The last applied preset and the recipe before it, for the Amount slider.
    @Published private(set) var appliedPreset: Preset?
    @Published var presetAmount: Double = 100
    private var recipeBeforePreset = EditRecipe()
    /// A camera/lens default preset suggested for this photo.
    @Published private(set) var suggestedDefault: Preset?
    let presets: PresetStore

    /// Size the preview is rendered at (long edge, pixels); set from the view's size.
    var previewPixels: CGFloat = 1600 { didSet { if abs(previewPixels - oldValue) > 64 { scheduleRender() } } }

    private var originalFile: URL?
    private var base: CIImage?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    private var undoStack: [EditRecipe] = []
    private var redoStack: [EditRecipe] = []
    private var committed = EditRecipe()
    /// The recipe as last saved to Immich (the original's when never edited). Reset and Cancel return here.
    @Published private(set) var savedRecipe = EditRecipe()
    private var drafts = EditDrafts(file: nil)

    /// Keeps unsaved changes on this Mac (when the editor is closed in a way that can't ask, e.g. auto-lock).
    func stashDraft() {
        guard hasChanges, let context else { return }
        drafts.put(recipe, for: context.version?.id ?? context.original.id)
        dirty = false
        savedRecipe = recipe   // so nothing else treats it as unsaved after stashing
    }

    /// Unsaved changes since the photo was opened or last saved.
    var hasChanges: Bool { canEdit && (recipe != savedRecipe || pendingCrop != nil) }

    /// A crop drawn but not yet applied (Crop mode still open), or nil.
    private var pendingCrop: EditRecipe.CropRect?? {
        guard cropping else { return nil }
        let crop: EditRecipe.CropRect? = cropDraft == .full ? nil : cropDraft
        return crop == recipe.geometry.crop ? nil : .some(crop)
    }

    /// Crop Apply: puts the drawn crop into the recipe and leaves Crop mode.
    func applyPendingCrop() {
        if let crop = pendingCrop { set { $0.geometry.crop = crop } }
        cropping = false
    }
    static var clipboard: (recipe: EditRecipe, panels: Set<DevelopPanel>)?

    init(library: LibraryModel) {
        self.library = library
        let registryFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DarkRoom/\(library.session.account.id.uuidString)/versions.json")
        versions = VersionManager(client: library.client, registry: VersionRegistry(file: registryFile))
        originals = OriginalCache(client: library.client, accountID: library.session.account.id)
        let userDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DarkRoom/\(library.session.account.id.uuidString)")
        presets = PresetStore(file: userDir.appending(path: "presets.json"))
        drafts = EditDrafts(file: userDir.appending(path: "edit-drafts.json"))
        LUTLibrary.shared.load(directory: userDir.appending(path: "luts"))
    }

    // MARK: Opening

    func open(_ assetID: String) async {
        guard assetID != self.assetID else { return }
        stashDraft()   // never saved silently; kept as a draft if anything bypassed the prompt
        self.assetID = assetID
        context = nil; preview = nil; base = nil; originalFile = nil; error = nil; histogram = nil
        appliedPreset = nil; hoverPreset = nil; suggestedDefault = nil
        undoStack = []; redoStack = []
        isLoading = true
        defer { isLoading = false }
        do {
            let context = try await versions.context(for: assetID)
            guard self.assetID == assetID else { return }
            self.context = context
            canEdit = context.original.ownerId == library.session.account.userID && context.original.type != .video
            status = "Downloading original…"
            let file = try await originals.file(for: context.original)
            guard self.assetID == assetID else { return }
            await versions.matchLibraryLook(original: context.original, file: file)
            guard self.assetID == assetID else { return }
            originalFile = file
            isRAW = RenderEngine.isRAW(file)
            rawNeutral = engine.rawNeutral(file)
            status = canEdit ? nil : (context.original.type == .video
                ? "Videos can be rotated from the Photo menu" : "View only: only your own photos can be edited")
            committed = context.recipe
            savedRecipe = context.recipe
            recipe = context.recipe
            dirty = false
            if canEdit, let draft = drafts.take(context.version?.id ?? context.original.id), draft != context.recipe {
                recipe = draft
                status = "Restored unsaved changes from your last session. Save to keep them, or Cancel."
            }
            if let version = context.version, let editor = try? await versions.record(of: version.id)?.editor {
                status = "Edited in \(editor). Develop edits start from the original and replace that version."
            }
            // Camera / lens default: suggested, or applied automatically if the user chose that.
            if context.recipe.isIdentity, canEdit, let exif = context.original.exifInfo,
               let preset = presets.cameraDefault(make: exif.make, model: exif.model, lens: exif.lensModel) {
                if presets.snapshot.autoApplyCameraDefaults { apply(preset) } else { suggestedDefault = preset }
            }
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
        var recipe = showBefore ? EditRecipe() : (hoverPreset.map { $0.apply(to: self.recipe) } ?? self.recipe)
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
                    // HDR previews keep values above 1 (shown with EDR on capable displays).
                    let cg = recipe.hdr
                        ? engine.cgImage(image, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, format: .RGBAh)
                        : engine.cgImage(image)
                    guard let cg else { return nil }
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
                if self.tool == .mask { self.renderMaskOverlay() }
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

    // MARK: Presets

    func apply(_ preset: Preset) {
        recipeBeforePreset = recipe
        appliedPreset = preset
        presetAmount = 100
        hoverPreset = nil
        suggestedDefault = nil
        set { $0 = preset.apply(to: $0) }
        presets.noteUsed(preset.id)
    }

    /// Re-applies the last preset at a new strength (0…200 %).
    func setPresetAmount(_ amount: Double, commit: Bool) {
        guard let preset = appliedPreset else { return }
        presetAmount = amount
        recipe = preset.apply(to: recipeBeforePreset, amount: amount / 100)
        if commit { self.commit() }
    }

    func saveAsPreset(name: String, folder: String, groups: Set<RecipeGroup>) {
        let preset = Preset(name: name, folder: folder, groups: groups, recipe: recipe)
        presets.save(preset)
        library.flash("Saved preset “\(name)”")
        objectWillChange.send()
    }

    // MARK: Masks and retouch

    enum Tool: Equatable { case none, mask, spot }
    @Published var tool: Tool = .none
    @Published var selectedMaskID: UUID?
    @Published var showMaskOverlay = true { didSet { renderMaskOverlay() } }
    @Published private(set) var maskOverlay: CGImage?
    @Published var brushSize: Double = 0.06
    @Published var brushFeather: Double = 50
    @Published var brushFlow: Double = 100
    @Published var spotMode: RetouchSpot.Mode = .heal
    @Published var spotSize: Double = 0.025
    @Published var selectedSpotID: UUID?
    private var overlayTask: Task<Void, Never>?

    var selectedMask: Mask? { recipe.masks.first { $0.id == selectedMaskID } }

    func addMask(_ kind: MaskKind) {
        let mask = Mask(name: kind.title, components: [MaskComponent(kind)])
        set { $0.masks.append(mask) }
        selectedMaskID = mask.id
        tool = .mask
        renderMaskOverlay()
    }

    func addComponent(_ kind: MaskKind, operation: MaskComponent.Operation) {
        guard let id = selectedMaskID else { return }
        set { r in
            guard let i = r.masks.firstIndex(where: { $0.id == id }) else { return }
            r.masks[i].components.append(MaskComponent(kind, operation: operation))
        }
        renderMaskOverlay()
    }

    func updateMask(commit: Bool = false, _ change: (inout Mask) -> Void) {
        guard let id = selectedMaskID, let i = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
        var r = recipe
        change(&r.masks[i])
        recipe = r
        if commit { self.commit() }
        renderMaskOverlay()
    }

    func deleteSelectedMask() {
        guard let id = selectedMaskID else { return }
        set { $0.masks.removeAll { $0.id == id } }
        selectedMaskID = recipe.masks.last?.id
        renderMaskOverlay()
    }

    /// Red overlay of the selected mask on the preview.
    func renderMaskOverlay() {
        overlayTask?.cancel()
        guard showMaskOverlay, tool == .mask, let mask = selectedMask, let file = originalFile, let preview else { maskOverlay = nil; return }
        let recipe = self.recipe, isRAW = self.isRAW, engine = self.engine
        let size = CGSize(width: preview.width, height: preview.height)
        overlayTask = Task {
            let image: CGImage? = await Task.detached(priority: .userInitiated) {
                guard let base = try? engine.base(file, recipe: recipe, draft: true, scaleFactor: isRAW ? 0.25 : 1) else { return nil }
                let oriented = engine.orient(base, recipe.geometry)
                var m = engine.frame(engine.maskImage(mask, oriented: oriented, sourceKey: file.path), recipe.geometry, lens: recipe.lens)
                m = m.transformed(by: CGAffineTransform(scaleX: size.width / m.extent.width, y: size.height / m.extent.height))
                let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.1, alpha: 0.5)).cropped(to: m.extent)
                let overlay = red.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: m.extent), kCIInputMaskImageKey: m])
                return engine.context.createCGImage(overlay, from: m.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }.value
            guard !Task.isCancelled else { return }
            maskOverlay = image
        }
    }

    /// Point on the (straightened, cropped) preview → normalised point in mask/retouch space.
    func toMaskSpace(_ p: CGPoint) -> [Double] {
        Self.framedToOriented(p, geometry: recipe.geometry, orientedSize: orientedSize)
    }

    /// Mask-space point → point on the preview (for drawing handles).
    func fromMaskSpace(_ p: [Double]) -> CGPoint {
        Self.orientedToFramed(p, geometry: recipe.geometry, orientedSize: orientedSize)
    }

    /// The photo's size after rotation/mirroring (aspect is what matters for mapping).
    var orientedSize: CGSize {
        let w = Double(context?.original.width ?? 3), h = Double(context?.original.height ?? 2)
        return ((recipe.geometry.quarterTurns % 2) == 1) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func framedToOriented(_ p: CGPoint, geometry g: EditRecipe.Geometry, orientedSize s: CGSize) -> [Double] {
        var u = Double(p.x), v = Double(p.y)
        if let c = g.crop { u = c.x + u * c.width; v = c.y + v * c.height }
        guard g.straighten != 0 else { return [u, v] }
        let a: Double = g.straighten * .pi / 180
        let inner = RenderEngine.inscribedSize(s, angle: a)
        let iw = Double(inner.width), ih = Double(inner.height), w = Double(s.width), h = Double(s.height)
        let dx = (u - 0.5) * iw, dy = (v - 0.5) * ih
        let ox = dx * Foundation.cos(a) + dy * Foundation.sin(a), oy = -dx * Foundation.sin(a) + dy * Foundation.cos(a)
        return [0.5 + ox / w, 0.5 + oy / h]
    }

    static func orientedToFramed(_ p: [Double], geometry g: EditRecipe.Geometry, orientedSize s: CGSize) -> CGPoint {
        var u = p[0], v = p[1]
        if g.straighten != 0 {
            let a: Double = g.straighten * .pi / 180
            let inner = RenderEngine.inscribedSize(s, angle: a)
            let ox = (u - 0.5) * Double(s.width), oy = (v - 0.5) * Double(s.height)
            let dx = ox * Foundation.cos(a) - oy * Foundation.sin(a), dy = ox * Foundation.sin(a) + oy * Foundation.cos(a)
            u = 0.5 + dx / Double(inner.width); v = 0.5 + dy / Double(inner.height)
        }
        if let c = g.crop { u = (u - c.x) / c.width; v = (v - c.y) / c.height }
        return CGPoint(x: u, y: v)
    }

    // Retouch

    func addSpot(at p: CGPoint) {
        let spot = RetouchSpot(mode: spotMode, center: toMaskSpace(p), radius: spotSize)
        set { $0.retouch.append(spot) }
        selectedSpotID = spot.id
    }

    func deleteSelectedSpot() {
        guard let id = selectedSpotID else { return }
        set { $0.retouch.removeAll { $0.id == id } }
        selectedSpotID = nil
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

    // MARK: Upright

    /// Lightroom-style Upright: analyses the photo (Vision) and sets straighten / vertical keystone.
    func applyUpright(_ mode: Upright.Mode) {
        guard let file = originalFile else { return }
        let recipe = self.recipe, isRAW = self.isRAW, engine = self.engine
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Double, EditRecipe.Transform)? in
                guard let base = try? engine.base(file, recipe: recipe, draft: true, scaleFactor: isRAW ? 0.3 : 1) else { return nil }
                return Upright.analyze(engine.orient(base, recipe.geometry), mode: mode)
            }.value
            guard let (straighten, transform) = result else { return }
            set { r in
                if mode != .vertical { r.geometry.straighten = straighten }
                if mode != .level { r.geometry.transform.vertical = transform.vertical }
            }
            library.flash(mode == .level && straighten == 0 ? "No horizon found" : "Upright \(mode.rawValue) applied")
        }
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
        // Save while the crop box is still open keeps the crop (as if Apply was clicked first).
        if cropping { applyPendingCrop() }
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
            savedRecipe = recipe
            status = nil
            switch outcome {
            case .unchanged: break
            case .builtInEdit:
                // Immich re-renders the photo with the crop/rotation; wait so the new look shows straight away.
                status = "Processing…"
                await versions.waitForThumbnails(context.original.id, replacing: context.original.thumbhash, timeout: .seconds(30))
                status = nil
                library.flash("Saved crop/rotation to Immich")
                self.context = try? await versions.context(for: context.original.id)
            case .version(let id):
                status = "Processing…"
                await versions.waitForThumbnails(id)
                status = nil
                library.flash("Saved edited version")
                if library.focusedAssetID == context.version?.id || library.focusedAssetID == context.original.id {
                    library.focusedAssetID = id
                }
                self.assetID = id
                self.context = try? await versions.context(for: id)
            case .reverted: library.flash("Reverted to original")
            }
            // Re-fetch the photo's month too, so its new thumbhash (cache key) replaces the old image everywhere.
            await library.timeline.refresh(assetIDs: Set([context.original.id, context.version?.id, self.assetID].compactMap { $0 }))
            library.detailsRevision += 1
            await library.pipeline.invalidate(assetID: context.original.id)
        } catch {
            self.error = "Couldn’t save: \(error.localizedDescription)"
            status = nil
        }
    }

    /// Reset: back to the saved version (or the original if it was never edited), staying in the editor. Undoable.
    func resetToSaved() {
        let saved = savedRecipe
        set { r in let s = r.snapshots; r = saved; r.snapshots = s }
        appliedPreset = nil
        cropping = false; eyedropper = false; tool = .none
    }

    /// Cancel: throw away unsaved changes (nothing is sent to Immich).
    func discardChanges() {
        appliedPreset = nil
        cropping = false; eyedropper = false; tool = .none
        committed = savedRecipe
        recipe = savedRecipe
        undoStack = []; redoStack = []
        dirty = false
    }

    func revertToOriginal() {
        set { r in let s = r.snapshots; r = EditRecipe(); r.snapshots = s }
        Task { await save() }
    }
}

typealias DevelopPanel = RecipeGroup

/// Unsaved editor changes kept on this Mac per photo (never uploaded until you Save).
struct EditDrafts {
    let file: URL?
    private var items: [String: EditRecipe] = [:]

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file) {
            items = (try? JSONDecoder().decode([String: EditRecipe].self, from: data)) ?? [:]
        }
    }

    mutating func put(_ recipe: EditRecipe, for id: String) { items[id] = recipe; write() }

    /// Returns and forgets the draft for a photo.
    mutating func take(_ id: String) -> EditRecipe? {
        guard let recipe = items.removeValue(forKey: id) else { return nil }
        write()
        return recipe
    }

    private func write() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: file, options: .atomic)
    }
}
