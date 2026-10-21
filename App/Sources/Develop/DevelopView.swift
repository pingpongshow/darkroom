import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

/// Develop module (D): live preview in the middle, Lightroom-style panels on the right.
struct DevelopView: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var develop: DevelopModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                DevelopToolbar(develop: develop)
                Divider().overlay(Theme.separator)
                ZStack {
                    Theme.gridBackground
                    DevelopCanvas(develop: develop)
                    if develop.isLoading || develop.isSaving {
                        VStack(spacing: 8) {
                            ProgressView()
                            if let status = develop.status { Text(status).font(.caption).foregroundStyle(.white.opacity(0.8)) }
                        }
                        .padding(14).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let error = develop.error {
                        Text(error).foregroundStyle(Theme.danger).padding().background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                            .frame(maxHeight: .infinity, alignment: .bottom).padding()
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("develop-canvas")
                if library.showFilmstrip { FilmstripView().frame(height: 86) }
            }
            Divider().overlay(Theme.separator)
            DevelopPanels(develop: develop).frame(width: 300)
        }
        .task(id: library.focusedAssetID) {
            if let id = library.focusedAssetID ?? library.orderedAssets.first?.id { await develop.open(id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("develop")
    }
}

struct DevelopToolbar: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var develop: DevelopModel
    @State private var showSync = false
    @State private var snapshotName = ""
    @State private var showSnapshot = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $develop.cropping) { Label("Crop", systemImage: "crop") }
                .toggleStyle(.button).help("Crop & straighten (R)").accessibilityIdentifier("develop-crop")
                .disabled(!develop.canEdit)
            Button { develop.set { $0.geometry.quarterTurns = ($0.geometry.quarterTurns + 3) % 4 } } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .help("Rotate 90° left").disabled(!develop.canEdit).accessibilityIdentifier("develop-rotate-left")
            Button { develop.set { $0.geometry.quarterTurns = ($0.geometry.quarterTurns + 1) % 4 } } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .help("Rotate 90° right").disabled(!develop.canEdit).accessibilityIdentifier("develop-rotate-right")
            Button { develop.set { $0.geometry.flipHorizontal.toggle() } } label: {
                Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("Flip horizontally").disabled(!develop.canEdit).accessibilityIdentifier("develop-flip")
            Divider().frame(height: 18)
            Toggle(isOn: Binding(get: { develop.tool == .spot }, set: { develop.tool = $0 ? .spot : .none })) {
                Label("Heal", systemImage: "bandage")
            }
            .toggleStyle(.button).help("Remove spots and blemishes (Q)").disabled(!develop.canEdit)
            Toggle(isOn: Binding(get: { develop.tool == .mask }, set: { develop.tool = $0 ? .mask : .none })) {
                Label("Masks", systemImage: "circle.dashed.inset.filled")
            }
            .toggleStyle(.button).help("Local adjustments: brush, gradients, subject, sky (M)").disabled(!develop.canEdit)
            Toggle(isOn: $develop.eyedropper) { Label("White Balance", systemImage: "eyedropper") }
                .toggleStyle(.button).help("White balance selector (W): click something neutral").disabled(!develop.canEdit)
            Toggle(isOn: $develop.showBefore) { Label("Before", systemImage: "rectangle.lefthalf.inset.filled") }
                .toggleStyle(.button).help("Before / after (\\)").accessibilityIdentifier("develop-before")
            Divider().frame(height: 18)
            Button { develop.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!develop.canUndo).help("Undo (⌘Z)")
            Button { develop.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!develop.canRedo).help("Redo (⇧⌘Z)")
            Menu {
                Button("Copy Settings (⇧⌘C)") { develop.copySettings() }
                Button("Paste Settings (⇧⌘V)") { develop.pasteSettings() }.disabled(DevelopModel.clipboard == nil)
                Button("Sync to Selection…") { showSync = true }.disabled(library.selection.count < 2)
                Divider()
                Button("New Snapshot…") { snapshotName = "Snapshot \(develop.recipe.snapshots.count + 1)"; showSnapshot = true }
                Divider()
                Button("Reset All Adjustments") { develop.reset() }
                Button("Revert to Original", role: .destructive) { develop.revertToOriginal() }
                    .disabled(develop.context?.version == nil && develop.context?.builtInEdits.isEmpty != false)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 36)
                .accessibilityIdentifier("develop-more")
            Spacer()
            if develop.isSaving { ProgressView().controlSize(.small) }
            if let context = develop.context, context.version != nil {
                Label("Edited version", systemImage: "square.stack.fill").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if develop.hasChanges {
                Text("Unsaved changes").font(.caption).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("develop-unsaved")
            }
            Button("Reset") { develop.resetToSaved() }
                .disabled(!develop.hasChanges || develop.isSaving)
                .help(develop.context?.version == nil
                      ? "Undo all changes since you opened the photo (back to the original); stay in the editor"
                      : "Undo all changes since the last save; stay in the editor")
                .accessibilityIdentifier("develop-reset")
            Button("Cancel") { library.cancelEditor() }
                .disabled(develop.isSaving)
                .help("Discard unsaved changes and close the editor")
                .accessibilityIdentifier("develop-cancel")
            Button("Save") { library.saveAndCloseEditor() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!develop.hasChanges || develop.isSaving)
                .help("Save the changes to Immich and close the editor (⌘S)")
                .accessibilityIdentifier("develop-save")
        }
        .labelStyle(DevelopToolLabelStyle())
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.panel)
        .sheet(isPresented: $showSync) {
            SyncSheet { panels in develop.sync(to: library.targetIDsForSync, panels: panels) }
        }
        .sheet(isPresented: $showSnapshot) {
            RenameSheet(title: "New Snapshot", name: $snapshotName) { develop.addSnapshot(named: $0) }
        }
    }
}

extension LibraryModel {
    /// Every selected photo (Develop's Sync uses the grid selection, not just the focused photo).
    var targetIDsForSync: [String] { orderedAssets.map(\.id).filter { selection.contains($0) } }
}

struct SyncSheet: View {
    var onSync: (Set<DevelopPanel>) -> Void
    @State private var panels = Set(DevelopPanel.allCases).subtracting([.geometry])
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync Settings").font(.headline)
            ForEach(DevelopPanel.allCases) { panel in
                Toggle(panel.rawValue, isOn: Binding(get: { panels.contains(panel) },
                                                    set: { if $0 { panels.insert(panel) } else { panels.remove(panel) } }))
            }
            HStack {
                Button("Check All") { panels = Set(DevelopPanel.allCases) }
                Button("Check None") { panels = [] }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Synchronize") { onSync(panels); dismiss() }.keyboardShortcut(.defaultAction).disabled(panels.isEmpty)
            }
        }
        .padding(20).frame(width: 360)
    }
}

// MARK: Canvas

struct DevelopCanvas: View {
    @ObservedObject var develop: DevelopModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if develop.cropping {
                    CropEditor(develop: develop, size: geo.size)
                } else if let preview = develop.preview, develop.tool != .none || develop.eyedropper {
                    // Tools draw over a plain image so their gestures always receive the mouse.
                    let scale = min(geo.size.width / CGFloat(preview.width), geo.size.height / CGFloat(preview.height), 1)
                    Image(decorative: preview, scale: 1).resizable()
                        .frame(width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .accessibilityIdentifier("develop-preview")
                    if develop.eyedropper {
                        EyedropperOverlay(image: preview) { develop.pickNeutral(at: $0) }
                    } else {
                        MaskCanvasOverlay(develop: develop, image: preview)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("mask-canvas")
                    }
                } else if let preview = develop.preview {
                    ZoomableImageView(image: preview, onZoomBeyondFit: {})
                        .overlay {
                            if develop.eyedropper {
                                EyedropperOverlay(image: preview) { develop.pickNeutral(at: $0) }
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if develop.showBefore {
                                Text("Before").font(.caption.weight(.semibold)).padding(6)
                                    .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).padding(10)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Develop preview")
                        .accessibilityIdentifier("develop-preview")
                }
            }
            .onAppear { develop.previewPixels = max(geo.size.width, geo.size.height) * (NSScreen.main?.backingScaleFactor ?? 2) }
            .onChange(of: geo.size) { _, size in
                develop.previewPixels = max(size.width, size.height) * (NSScreen.main?.backingScaleFactor ?? 2)
            }
        }
    }
}

/// Click on the fitted image to sample a neutral point.
struct EyedropperOverlay: View {
    let image: CGImage
    var onPick: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(container: geo.size)
            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() } }
                .onTapGesture { location in
                    guard fitted.contains(location) else { return }
                    onPick(CGPoint(x: (location.x - fitted.minX) / fitted.width, y: (location.y - fitted.minY) / fitted.height))
                }
        }
    }

    private func fittedRect(container: CGSize) -> CGRect {
        let scale = min(container.width / CGFloat(image.width), container.height / CGFloat(image.height), 1)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}

// MARK: Crop

/// Crop & straighten: the uncropped (but rotated/straightened) photo with a draggable crop rectangle.
struct CropEditor: View {
    @ObservedObject var develop: DevelopModel
    let size: CGSize
    /// The crop box being drawn; kept in the model so Save and leaving the editor apply it too.
    private var draft: EditRecipe.CropRect {
        get { develop.cropDraft }
        nonmutating set { develop.cropDraft = newValue }
    }
    @State private var dragStart: EditRecipe.CropRect?
    @State private var overlay = 0

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                if let preview = develop.preview {
                    let frame = fitted(preview, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: preview, scale: 1).resizable().frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        let rect = CGRect(x: frame.minX + draft.x * frame.width, y: frame.minY + draft.y * frame.height,
                                          width: draft.width * frame.width, height: draft.height * frame.height)
                        // Dim outside the crop.
                        Path { p in p.addRect(frame); p.addRect(rect) }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        CropGrid(kind: overlay).stroke(.white.opacity(0.5), lineWidth: 0.5).frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        Rectangle().stroke(.white, lineWidth: 1.5).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                            .contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { v in move(v.translation, frame: frame) }.onEnded { _ in dragStart = nil })
                            .accessibilityIdentifier("crop-rect")
                        ForEach(Corner.allCases, id: \.self) { corner in
                            Circle().fill(.white).frame(width: 12, height: 12)
                                .position(corner.point(in: rect))
                                .gesture(DragGesture().onChanged { v in resize(corner, v.translation, frame: frame) }.onEnded { _ in dragStart = nil })
                        }
                    }
                }
            }
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Picker("Aspect", selection: Binding(get: { develop.recipe.geometry.aspect },
                                                        set: { a in develop.set { $0.geometry.aspect = a }; constrain() })) {
                        ForEach(EditRecipe.Aspect.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .fixedSize()
                    Button { swapOrientation() } label: { Image(systemName: "rectangle.portrait.rotate") }.help("Swap orientation (X)")
                    Button { develop.set { $0.geometry.quarterTurns = ($0.geometry.quarterTurns + 3) % 4 } } label: { Image(systemName: "rotate.left") }
                        .help("Rotate left")
                    Button { develop.set { $0.geometry.quarterTurns = ($0.geometry.quarterTurns + 1) % 4 } } label: { Image(systemName: "rotate.right") }
                        .help("Rotate right")
                    Button { develop.set { $0.geometry.flipHorizontal.toggle() } } label: { Image(systemName: "arrow.left.and.right") }
                        .help("Flip horizontal")
                    Button { develop.set { $0.geometry.flipVertical.toggle() } } label: { Image(systemName: "arrow.up.and.down") }
                        .help("Flip vertical")
                    Button { overlay = (overlay + 1) % 3 } label: { Image(systemName: "squareshape.split.3x3") }.help("Overlay (O)")
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Text("Straighten").font(.caption)
                    Slider(value: Binding(get: { develop.recipe.geometry.straighten },
                                          set: { v in develop.recipe.geometry.straighten = v }),
                           in: -45...45, onEditingChanged: { if !$0 { develop.commit() } })
                        .frame(minWidth: 100, maxWidth: 220)
                        .accessibilityIdentifier("crop-straighten")
                    Text(String(format: "%.1f°", develop.recipe.geometry.straighten)).font(.caption.monospacedDigit()).frame(width: 44)
                    Spacer(minLength: 0)
                    Button("Reset") { draft = .full; develop.set { $0.geometry = EditRecipe.Geometry() } }
                    Button("Cancel") { develop.cropping = false }
                    Button("Apply") { apply() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("crop-apply")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private func fitted(_ image: CGImage, in container: CGSize) -> CGRect {
        let inset = container.insetBy(16)
        let scale = min(inset.width / CGFloat(image.width), inset.height / CGFloat(image.height))
        let s = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (container.width - s.width) / 2, y: (container.height - s.height) / 2, width: s.width, height: s.height)
    }

    private var aspectRatio: Double? {
        guard let preview = develop.preview else { return nil }
        let original = Double(preview.width) / Double(preview.height)
        return develop.recipe.geometry.aspect.ratio(original: original)
    }

    private func move(_ t: CGSize, frame: CGRect) {
        if dragStart == nil { dragStart = draft }
        guard let start = dragStart else { return }
        draft.x = min(max(0, start.x + t.width / frame.width), 1 - start.width)
        draft.y = min(max(0, start.y + t.height / frame.height), 1 - start.height)
    }

    private func resize(_ corner: Corner, _ t: CGSize, frame: CGRect) {
        if dragStart == nil { dragStart = draft }
        guard let s = dragStart else { return }
        let dx = t.width / frame.width, dy = t.height / frame.height
        var minX = s.x, minY = s.y, maxX = s.x + s.width, maxY = s.y + s.height
        switch corner {
        case .topLeft: minX += dx; minY += dy
        case .topRight: maxX += dx; minY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        }
        minX = max(0, min(minX, maxX - 0.05)); maxX = min(1, max(maxX, minX + 0.05))
        minY = max(0, min(minY, maxY - 0.05)); maxY = min(1, max(maxY, minY + 0.05))
        draft = .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio = aspectRatio, let preview = develop.preview {
            // Keep the pixel aspect: adjust height from width.
            let imageAspect = Double(preview.width) / Double(preview.height)
            let h = min(draft.width * imageAspect / ratio, 1)
            if [.topLeft, .topRight].contains(corner) { draft.y = max(0, draft.y + draft.height - h) }
            draft.height = h
            if draft.y + draft.height > 1 { draft.y = 1 - draft.height }
        }
    }

    private func constrain() {
        guard let ratio = aspectRatio, let preview = develop.preview else { return }
        let imageAspect = Double(preview.width) / Double(preview.height)
        var w = draft.width, h = w * imageAspect / ratio
        if h > 1 { h = 1; w = h * ratio / imageAspect }
        draft = .init(x: min(draft.x, 1 - w), y: min(draft.y, 1 - h), width: w, height: h)
    }

    /// Portrait ⇄ landscape: the crop's pixel width and height swap (scaled down to fit).
    private func swapOrientation() {
        guard let preview = develop.preview else { return }
        let W = Double(preview.width), H = Double(preview.height)
        var w = draft.height * H / W, h = draft.width * W / H
        let fit = min(1, 1 / max(w, h))
        w *= fit; h *= fit
        let cx = draft.x + draft.width / 2, cy = draft.y + draft.height / 2
        draft = .init(x: min(max(0, cx - w / 2), 1 - w), y: min(max(0, cy - h / 2), 1 - h), width: w, height: h)
    }

    private func apply() { develop.applyPendingCrop() }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }
}

private extension CGSize {
    func insetBy(_ d: CGFloat) -> CGSize { CGSize(width: max(1, width - 2 * d), height: max(1, height - 2 * d)) }
}

/// Rule of thirds / golden ratio / grid.
struct CropGrid: Shape {
    var kind: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let fractions: [CGFloat] = switch kind {
        case 1: [0.382, 0.618]
        case 2: [0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875]
        default: [1.0 / 3, 2.0 / 3]
        }
        for f in fractions {
            p.move(to: CGPoint(x: rect.minX + rect.width * f, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + rect.width * f, y: rect.maxY))
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * f)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))
        }
        return p
    }
}

/// Develop toolbar buttons: icon and title, collapsing to icons only in narrow windows.
struct DevelopToolLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { configuration.icon; configuration.title }
            configuration.icon
        }
    }
}
