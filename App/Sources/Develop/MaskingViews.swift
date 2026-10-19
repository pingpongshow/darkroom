import SwiftUI
import AppKit
import DarkRoomCore

// MARK: Panel

/// Masks: list, add (gradients, brush, AI, ranges), components, and the selected mask's adjustments.
struct MasksPanel: View {
    @ObservedObject var develop: DevelopModel

    var body: some View {
        HStack {
            Menu {
                addItems { develop.addMask($0) }
            } label: { Label("Add Mask", systemImage: "plus.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("mask-add")
            Spacer()
            Toggle("Overlay", isOn: $develop.showMaskOverlay).toggleStyle(.checkbox).help("Show the mask in red (O)")
        }
        if develop.recipe.masks.isEmpty {
            Text("Gradients, brush, Select Subject / Sky / People, and colour, luminance or depth ranges.")
                .foregroundStyle(Theme.textTertiary)
        }
        ForEach(develop.recipe.masks) { mask in
            HStack {
                Button {
                    develop.updateMaskEnabled(mask.id)
                } label: { Image(systemName: mask.isEnabled ? "eye" : "eye.slash") }.buttonStyle(.borderless)
                Text(mask.name).lineLimit(1)
                Spacer()
                Text(mask.components.map(\.kind.title).joined(separator: " + ")).font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 4).fill(develop.selectedMaskID == mask.id ? Theme.panelRaised : .clear))
            .contentShape(Rectangle())
            .onTapGesture { develop.selectedMaskID = mask.id; develop.tool = .mask; develop.renderMaskOverlay() }
            .accessibilityIdentifier("mask-\(mask.name)")
        }
        if let mask = develop.selectedMask {
            Divider()
            HStack {
                Menu("Add") { addItems { develop.addComponent($0, operation: .add) } }.fixedSize()
                Menu("Subtract") { addItems { develop.addComponent($0, operation: .subtract) } }.fixedSize()
                Menu("Intersect") { addItems { develop.addComponent($0, operation: .intersect) } }.fixedSize()
                Spacer()
                Toggle("Invert", isOn: Binding(get: { mask.inverted }, set: { v in develop.updateMask(commit: true) { $0.inverted = v } }))
                    .toggleStyle(.checkbox)
                Button(role: .destructive) { develop.deleteSelectedMask() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            .controlSize(.small)
            if mask.components.contains(where: { if case .brush = $0.kind { true } else { false } }) {
                BrushControls(develop: develop)
            }
            ForEach(mask.components) { component in
                componentControls(component)
            }
            Text("Adjustments").font(.caption2).foregroundStyle(Theme.textTertiary).padding(.top, 4)
            ForEach(LocalSlider.all, id: \.title) { slider in
                LocalAdjustmentSlider(develop: develop, slider: slider)
            }
        }
    }

    @ViewBuilder private func addItems(_ action: @escaping (MaskKind) -> Void) -> some View {
        Button("Linear Gradient (M)") { action(.linear(start: [0.5, 0.15], end: [0.5, 0.55])) }
        Button("Radial Gradient (⇧M)") { action(.radial(center: [0.5, 0.5], radius: [0.25, 0.25], angle: 0, feather: 50, inside: true)) }
        Button("Brush (K)") { action(.brush(strokes: [])) }
        Divider()
        Button("Select Subject") { action(.subject) }
        Button("Select People") { action(.people) }
        Button("Select Sky") { action(.sky) }
        Button("Select Background") { action(.background) }
        Divider()
        Button("Colour Range") { action(.colorRange(hue: 30, saturation: 0.5, range: 30)) }
        Button("Luminance Range") { action(.luminanceRange(low: 0.7, high: 1, smoothness: 30)) }
        Button("Depth Range") { action(.depthRange(near: 0, far: 0.4, smoothness: 30)) }
    }

    @ViewBuilder private func componentControls(_ component: MaskComponent) -> some View {
        switch component.kind {
        case .radial(let c, let r, let angle, let feather, let inside):
            componentSlider("Feather", value: feather, range: 0...100, id: component.id) { .radial(center: c, radius: r, angle: angle, feather: $0, inside: inside) }
        case .colorRange(let hue, let sat, let range):
            componentSlider("Hue", value: hue, range: 0...360, id: component.id) { .colorRange(hue: $0, saturation: sat, range: range) }
            componentSlider("Range", value: range, range: 1...100, id: component.id) { .colorRange(hue: hue, saturation: sat, range: $0) }
        case .luminanceRange(let low, let high, let smooth):
            componentSlider("Low", value: low * 100, range: 0...100, id: component.id) { .luminanceRange(low: $0 / 100, high: high, smoothness: smooth) }
            componentSlider("High", value: high * 100, range: 0...100, id: component.id) { .luminanceRange(low: low, high: $0 / 100, smoothness: smooth) }
            componentSlider("Smoothness", value: smooth, range: 0...100, id: component.id) { .luminanceRange(low: low, high: high, smoothness: $0) }
        case .depthRange(let near, let far, let smooth):
            componentSlider("Near", value: near * 100, range: 0...100, id: component.id) { .depthRange(near: $0 / 100, far: far, smoothness: smooth) }
            componentSlider("Far", value: far * 100, range: 0...100, id: component.id) { .depthRange(near: near, far: $0 / 100, smoothness: smooth) }
        default:
            EmptyView()
        }
    }

    private func componentSlider(_ title: String, value: Double, range: ClosedRange<Double>, id: UUID,
                                 make: @escaping (Double) -> MaskKind) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading).foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(get: { value }, set: { v in
                develop.updateMask { m in if let i = m.components.firstIndex(where: { $0.id == id }) { m.components[i].kind = make(v) } }
            }), in: range, onEditingChanged: { if !$0 { develop.commit() } })
            .controlSize(.mini)
        }
    }
}

extension DevelopModel {
    func updateMaskEnabled(_ id: UUID) {
        set { r in if let i = r.masks.firstIndex(where: { $0.id == id }) { r.masks[i].isEnabled.toggle() } }
    }
}

struct BrushControls: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        VStack(spacing: 2) {
            labeled("Size") { Slider(value: $develop.brushSize, in: 0.005...0.3).controlSize(.mini) }
            labeled("Feather") { Slider(value: $develop.brushFeather, in: 0...100).controlSize(.mini) }
            labeled("Flow") { Slider(value: $develop.brushFlow, in: 5...100).controlSize(.mini) }
            Text("Paint on the photo · hold ⌥ to erase").font(.caption2).foregroundStyle(Theme.textTertiary)
        }
    }
    private func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(t).frame(width: 50, alignment: .leading).foregroundStyle(Theme.textSecondary); c() }
    }
}

struct LocalSlider: @unchecked Sendable {  // immutable key paths
    let title: String
    let keyPath: WritableKeyPath<LocalAdjustments, Double>
    var range: ClosedRange<Double> = -100...100
    static let all: [LocalSlider] = [
        .init(title: "Exposure", keyPath: \.exposure, range: -4...4), .init(title: "Contrast", keyPath: \.contrast),
        .init(title: "Highlights", keyPath: \.highlights), .init(title: "Shadows", keyPath: \.shadows),
        .init(title: "Whites", keyPath: \.whites), .init(title: "Blacks", keyPath: \.blacks),
        .init(title: "Temp", keyPath: \.temperature), .init(title: "Tint", keyPath: \.tint),
        .init(title: "Hue", keyPath: \.hue, range: -180...180), .init(title: "Saturation", keyPath: \.saturation),
        .init(title: "Texture", keyPath: \.texture), .init(title: "Clarity", keyPath: \.clarity),
        .init(title: "Dehaze", keyPath: \.dehaze), .init(title: "Sharpness", keyPath: \.sharpness),
        .init(title: "Noise", keyPath: \.noise, range: 0...100),
        .init(title: "Colour hue", keyPath: \.overlayHue, range: 0...360), .init(title: "Colour amount", keyPath: \.overlayStrength, range: 0...100),
    ]
}

struct LocalAdjustmentSlider: View {
    @ObservedObject var develop: DevelopModel
    let slider: LocalSlider

    var body: some View {
        let value = develop.selectedMask?.adjust[keyPath: slider.keyPath] ?? 0
        VStack(spacing: 1) {
            HStack {
                Text(slider.title).foregroundStyle(Theme.textSecondary)
                    .onTapGesture(count: 2) { develop.updateMask(commit: true) { $0.adjust[keyPath: slider.keyPath] = 0 } }
                Spacer()
                Text(slider.range.upperBound <= 4 ? String(format: "%.2f", value) : String(format: "%.0f", value))
                    .monospacedDigit().foregroundStyle(value == 0 ? Theme.textTertiary : Theme.text)
            }
            Slider(value: Binding(get: { value }, set: { v in develop.updateMask { $0.adjust[keyPath: slider.keyPath] = v } }),
                   in: slider.range, onEditingChanged: { if !$0 { develop.commit() } })
                .controlSize(.mini)
                .accessibilityIdentifier("mask-slider-\(slider.title)")
        }
    }
}

/// Spot removal options (Q).
struct RetouchPanel: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { develop.tool == .spot }, set: { develop.tool = $0 ? .spot : .none })) {
                Label("Spot Removal (Q)", systemImage: "bandage")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("retouch-tool")
            Spacer()
        }
        Picker("Mode", selection: $develop.spotMode) {
            Text("Heal").tag(RetouchSpot.Mode.heal); Text("Clone").tag(RetouchSpot.Mode.clone); Text("Remove").tag(RetouchSpot.Mode.remove)
        }
        .pickerStyle(.segmented)
        HStack { Text("Size").foregroundStyle(Theme.textSecondary); Slider(value: $develop.spotSize, in: 0.005...0.15).controlSize(.mini) }
        Toggle("Red-eye correction", isOn: Binding(get: { develop.recipe.redEye }, set: { v in develop.set { $0.redEye = v } }))
        if !develop.recipe.retouch.isEmpty {
            HStack {
                Text("\(develop.recipe.retouch.count) spot\(develop.recipe.retouch.count == 1 ? "" : "s")").foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Clear All") { develop.set { $0.retouch = [] } }
            }
        }
        Text("Click a spot to fix it; drag the source circle to choose where it copies from. Delete removes the selected spot.")
            .font(.caption2).foregroundStyle(Theme.textTertiary)
    }
}

// MARK: Canvas overlay

/// Drawn over the fitted preview: mask overlay, gradient handles, brush painting and retouch spots.
struct MaskCanvasOverlay: View {
    @ObservedObject var develop: DevelopModel
    let image: CGImage
    @State private var stroke: [CGPoint] = []
    @State private var dragStart: [Double]?

    var body: some View {
        GeometryReader { geo in
            let rect = fitted(geo.size)
            ZStack(alignment: .topLeading) {
                // Always fill the canvas so clicks register even with nothing drawn yet.
                Color.clear.frame(width: geo.size.width, height: geo.size.height)
                if develop.tool == .mask, let overlay = develop.maskOverlay {
                    Image(decorative: overlay, scale: 1).resizable().frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                }
                if develop.tool == .mask, let mask = develop.selectedMask { handles(mask, rect: rect) }
                if develop.tool == .spot { spots(rect: rect) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in drag(v, rect: rect) }
                .onEnded { v in dragEnded(v, rect: rect) })
        }
    }

    private func fitted(_ container: CGSize) -> CGRect {
        let scale = min(container.width / CGFloat(image.width), container.height / CGFloat(image.height), 1)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func normalized(_ p: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
    }

    private func onScreen(_ p: [Double], _ rect: CGRect) -> CGPoint {
        let f = develop.fromMaskSpace(p)
        return CGPoint(x: rect.minX + f.x * rect.width, y: rect.minY + f.y * rect.height)
    }

    @ViewBuilder private func handles(_ mask: Mask, rect: CGRect) -> some View {
        ForEach(mask.components) { component in
            switch component.kind {
            case .linear(let start, let end):
                let a = onScreen(start, rect), b = onScreen(end, rect)
                Path { p in p.move(to: a); p.addLine(to: b) }.stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Circle().stroke(.white, lineWidth: 2).frame(width: 12, height: 12).position(a)
                Circle().fill(.white).frame(width: 8, height: 8).position(b)
            case .radial(let center, let radius, _, _, _):
                let c = onScreen(center, rect)
                let edge = onScreen([center[0] + radius[0], center[1]], rect)
                let edgeY = onScreen([center[0], center[1] + radius[1]], rect)
                Ellipse().stroke(.white, lineWidth: 1.5)
                    .frame(width: abs(edge.x - c.x) * 2, height: abs(edgeY.y - c.y) * 2).position(c)
                Circle().fill(.white).frame(width: 8, height: 8).position(c)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func spots(rect: CGRect) -> some View {
        ForEach(develop.recipe.retouch) { spot in
            let c = onScreen(spot.center, rect)
            let r = spot.radius * max(rect.width, rect.height)
            Circle().stroke(develop.selectedSpotID == spot.id ? Color.white : .white.opacity(0.6), lineWidth: 1.5)
                .frame(width: r * 2, height: r * 2).position(c)
            if let source = spot.source {
                let s = onScreen(source, rect)
                Path { p in p.move(to: c); p.addLine(to: s) }.stroke(.white.opacity(0.6), lineWidth: 1)
                Circle().stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: r * 2, height: r * 2).position(s)
            }
        }
    }

    // MARK: Interaction

    private func drag(_ v: DragGesture.Value, rect: CGRect) {
        let p = normalized(v.location, rect)
        switch develop.tool {
        case .mask:
            guard let mask = develop.selectedMask, let component = mask.components.last else { return }
            switch component.kind {
            case .brush:
                stroke.append(p)
            case .linear(let start, _):
                // Drag from the start handle redraws the gradient; elsewhere moves the end.
                let s = develop.toMaskSpace(normalized(v.startLocation, rect))
                if dragStart == nil { dragStart = hypot(s[0] - start[0], s[1] - start[1]) < 0.05 ? start : s }
                let begin = dragStart ?? s
                setLast(.linear(start: begin, end: develop.toMaskSpace(p)))
            case .radial(_, let radius, let angle, let feather, let inside):
                // Drag moves the centre; ⌥-drag sets the size.
                if NSEvent.modifierFlags.contains(.option) {
                    let c = develop.toMaskSpace(normalized(v.startLocation, rect)), q = develop.toMaskSpace(p)
                    setLast(.radial(center: c, radius: [max(0.02, abs(q[0] - c[0])), max(0.02, abs(q[1] - c[1]))], angle: angle, feather: feather, inside: inside))
                } else {
                    setLast(.radial(center: develop.toMaskSpace(p), radius: radius, angle: angle, feather: feather, inside: inside))
                }
            default:
                break
            }
        case .spot:
            if let id = develop.selectedSpotID, v.translation != .zero,
               let spot = develop.recipe.retouch.first(where: { $0.id == id }) {
                // Dragging away from a new spot sets its source.
                let start = develop.toMaskSpace(normalized(v.startLocation, rect))
                if hypot(start[0] - spot.center[0], start[1] - spot.center[1]) < spot.radius * 1.5 {
                    var r = develop.recipe
                    if let i = r.retouch.firstIndex(where: { $0.id == id }) { r.retouch[i].source = develop.toMaskSpace(p) }
                    develop.recipe = r
                }
            }
        case .none:
            break
        }
    }

    private func dragEnded(_ v: DragGesture.Value, rect: CGRect) {
        defer { dragStart = nil }
        switch develop.tool {
        case .mask:
            guard let mask = develop.selectedMask, let component = mask.components.last else { return }
            if case .brush(var strokes) = component.kind, !stroke.isEmpty {
                strokes.append(BrushStroke(points: stroke.map { develop.toMaskSpace($0) }, size: develop.brushSize,
                                           feather: develop.brushFeather, flow: develop.brushFlow,
                                           erase: NSEvent.modifierFlags.contains(.option)))
                stroke = []
                setLast(.brush(strokes: strokes))
            }
            develop.commit()
        case .spot:
            if v.translation == .zero || hypot(v.translation.width, v.translation.height) < 3 {
                let p = normalized(v.location, rect)
                if let hit = develop.recipe.retouch.first(where: { s in
                    let c = develop.toMaskSpace(p); return hypot(c[0] - s.center[0], c[1] - s.center[1]) < s.radius
                }) {
                    develop.selectedSpotID = hit.id
                } else {
                    develop.addSpot(at: p)
                }
            } else {
                develop.commit()
            }
        case .none:
            break
        }
    }

    private func setLast(_ kind: MaskKind) {
        develop.updateMask { m in if !m.components.isEmpty { m.components[m.components.count - 1].kind = kind } }
    }
}
