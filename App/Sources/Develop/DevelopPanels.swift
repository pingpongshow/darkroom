import SwiftUI
import DarkRoomCore

/// The right-hand Develop panels.
struct DevelopPanels: View {
    @ObservedObject var develop: DevelopModel
    @AppStorage("developExpanded", store: .darkRoom) private var expandedRaw = "Tone,Presence,White Balance"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let histogram = develop.histogram {
                    HistogramView(histogram: histogram).frame(height: 90).padding(12)
                } else {
                    Rectangle().fill(Theme.panelRaised).frame(height: 90).padding(12)
                }
                Group {
                    section("Profile & RAW") { ProfilePanel(develop: develop) }
                    section("White Balance") { WhiteBalancePanel(develop: develop) }
                    section("Tone") { TonePanel(develop: develop) }
                    section("Presence") { PresencePanel(develop: develop) }
                    section("Tone Curve") { ToneCurvePanel(develop: develop) }
                    section("Colour Mixer") { MixerPanel(develop: develop) }
                    section("Colour Grading") { GradingPanel(develop: develop) }
                    section("Detail") { DetailPanel(develop: develop) }
                    section("Effects") { EffectsPanel(develop: develop) }
                    section("Masks") { MasksPanel(develop: develop) }
                    section("Retouch") { RetouchPanel(develop: develop) }
                    section("Snapshots") { SnapshotsPanel(develop: develop) }
                }
                .disabled(!develop.canEdit || develop.context == nil)
            }
            .font(.system(size: 11))
        }
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("develop-panels")
    }

    private var expanded: Set<String> { Set(expandedRaw.split(separator: ",").map(String.init)) }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        let isOpen = expanded.contains(title)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                var set = expanded
                if isOpen { set.remove(title) } else { set.insert(title) }
                expandedRaw = set.sorted().joined(separator: ",")
            } label: {
                HStack {
                    Text(title).panelHeader()
                    Spacer()
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("panel-\(title)")
            if isOpen {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            Divider().overlay(Theme.separator)
        }
    }
}

// MARK: Slider

/// Lightroom-style slider: label, value, double-click the label to reset, one undo step per drag.
struct DevelopSlider: View {
    @ObservedObject var develop: DevelopModel
    let title: String
    let keyPath: WritableKeyPath<EditRecipe, Double>
    var range: ClosedRange<Double> = -100...100
    var step: Double = 1
    var format: String = "%.0f"
    var defaultValue: Double = 0
    var track: [Color]? = nil

    var body: some View {
        VStack(spacing: 1) {
            HStack {
                Text(title).foregroundStyle(Theme.textSecondary)
                    .onTapGesture(count: 2) { develop.set { $0[keyPath: keyPath] = defaultValue } }
                    .help("Double-click to reset")
                Spacer()
                TextField("", value: Binding(get: { develop.recipe[keyPath: keyPath] },
                                             set: { v in develop.set { $0[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, v)) } }),
                          format: .number.precision(.fractionLength(format.contains(".2") ? 2 : (format.contains(".1") ? 1 : 0))))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 48)
                    .foregroundStyle(develop.recipe[keyPath: keyPath] == defaultValue ? Theme.textTertiary : Theme.text)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { develop.recipe[keyPath: keyPath] }, set: { develop.recipe[keyPath: keyPath] = $0 }),
                   in: range, step: step, onEditingChanged: { editing in if !editing { develop.commit() } })
                .controlSize(.mini)
                .background(alignment: .center) {
                    if let track {
                        LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing).frame(height: 3).clipShape(Capsule())
                            .padding(.horizontal, 6).opacity(0.8)
                    }
                }
                .accessibilityIdentifier("slider-\(title)")
        }
    }
}

// MARK: Panels

struct ProfilePanel: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        Picker("Profile", selection: Binding(get: { develop.recipe.profile }, set: { p in develop.set { $0.profile = p } })) {
            ForEach(EditRecipe.Profile.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("develop-profile")
        DevelopSlider(develop: develop, title: "Amount", keyPath: \.profileAmount, range: 0...200, defaultValue: 100)
        Picker("LUT", selection: Binding(get: { develop.recipe.lutProfile ?? "" },
                                         set: { id in develop.set { $0.lutProfile = id.isEmpty ? nil : id } })) {
            Text("None").tag("")
            let luts = LUTLibrary.shared.all
            ForEach(Array(Set(luts.map(\.group))).sorted(), id: \.self) { group in
                Section(group) { ForEach(luts.filter { $0.group == group }) { Text($0.name).tag($0.id) } }
            }
        }
        .accessibilityIdentifier("develop-lut")
        if develop.recipe.lutProfile != nil {
            DevelopSlider(develop: develop, title: "LUT amount", keyPath: \.lutAmount, range: 0...100, defaultValue: 100)
        }
        if develop.isRAW {
            Text("RAW engine").font(.caption2).foregroundStyle(Theme.textTertiary).padding(.top, 4)
            DevelopSlider(develop: develop, title: "Boost", keyPath: \.raw.boost, range: 0...1, step: 0.01, format: "%.2f", defaultValue: 1)
            DevelopSlider(develop: develop, title: "Shadow boost", keyPath: \.raw.boostShadows, range: 0...1, step: 0.01, format: "%.2f", defaultValue: 1)
            DevelopSlider(develop: develop, title: "Local tone mapping", keyPath: \.raw.localToneMapping, range: 0...1, step: 0.01, format: "%.2f", defaultValue: 0.5)
            DevelopSlider(develop: develop, title: "Highlight recovery (EDR)", keyPath: \.raw.extendedDynamicRange, range: 0...2, step: 0.01, format: "%.2f")
            DevelopSlider(develop: develop, title: "Moiré reduction", keyPath: \.raw.moireReduction, range: 0...1, step: 0.01, format: "%.2f")
            Toggle("Lens corrections", isOn: Binding(get: { develop.recipe.raw.lensCorrection },
                                                     set: { v in develop.set { $0.raw.lensCorrection = v } }))
        }
    }
}

struct WhiteBalancePanel: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { develop.recipe.whiteBalance }, set: { mode in
                develop.set {
                    $0.whiteBalance = mode
                    $0.neutralPoint = nil
                    if let preset = mode.preset, develop.isRAW { $0.temperature = preset.kelvin; $0.tint = preset.tint }
                    if mode == .asShot { $0.temperature = 0; $0.tint = 0 }
                }
                if mode == .auto { develop.autoWhiteBalance() }
            })) {
                ForEach(EditRecipe.WhiteBalance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .accessibilityIdentifier("develop-wb")
            Button { develop.eyedropper.toggle() } label: { Image(systemName: "eyedropper") }.help("White balance selector (W)")
        }
        if develop.isRAW {
            // Shows Kelvin; relative shifts (from presets) are converted from the as-shot value.
            let asShot = develop.rawNeutral?.kelvin ?? 5500
            let kelvin = develop.recipe.temperature >= 1000 ? develop.recipe.temperature
                : asShot * (1 + develop.recipe.temperature / 100 * 0.6)
            HStack {
                Text("Temp (K)").foregroundStyle(Theme.textSecondary)
                    .onTapGesture(count: 2) { develop.set { $0.temperature = 0; $0.whiteBalance = .asShot } }
                Spacer()
                Text("\(Int(kelvin))").monospacedDigit()
            }
            Slider(value: Binding(get: { kelvin }, set: { v in develop.recipe.temperature = v; develop.recipe.whiteBalance = .custom }),
                   in: 2000...20000, step: 50, onEditingChanged: { if !$0 { develop.commit() } })
                .controlSize(.mini)
                .accessibilityIdentifier("slider-Temp")
            DevelopSlider(develop: develop, title: "Tint", keyPath: \.tint, range: -150...150, track: [.green, .white, .pink])
        } else {
            DevelopSlider(develop: develop, title: "Temp", keyPath: \.temperature, track: [.blue, .white, .yellow])
            DevelopSlider(develop: develop, title: "Tint", keyPath: \.tint, range: -150...150, track: [.green, .white, .pink])
        }
    }
}

struct TonePanel: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        HStack {
            Spacer()
            Button("Auto") { develop.autoTone() }.controlSize(.small).help("Auto tone (⌘U)").accessibilityIdentifier("develop-auto")
        }
        DevelopSlider(develop: develop, title: "Exposure", keyPath: \.exposure, range: -5...5, step: 0.01, format: "%.2f")
        DevelopSlider(develop: develop, title: "Contrast", keyPath: \.contrast)
        DevelopSlider(develop: develop, title: "Highlights", keyPath: \.highlights)
        DevelopSlider(develop: develop, title: "Shadows", keyPath: \.shadows)
        DevelopSlider(develop: develop, title: "Whites", keyPath: \.whites)
        DevelopSlider(develop: develop, title: "Blacks", keyPath: \.blacks)
    }
}

struct PresencePanel: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        DevelopSlider(develop: develop, title: "Texture", keyPath: \.texture)
        DevelopSlider(develop: develop, title: "Clarity", keyPath: \.clarity)
        DevelopSlider(develop: develop, title: "Dehaze", keyPath: \.dehaze)
        DevelopSlider(develop: develop, title: "Vibrance", keyPath: \.vibrance)
        DevelopSlider(develop: develop, title: "Saturation", keyPath: \.saturation)
    }
}

struct ToneCurvePanel: View {
    @ObservedObject var develop: DevelopModel
    enum Channel: String, CaseIterable { case rgb = "RGB", red = "Red", green = "Green", blue = "Blue" }
    @State private var channel: Channel = .rgb

    var body: some View {
        Text("Parametric").font(.caption2).foregroundStyle(Theme.textTertiary)
        DevelopSlider(develop: develop, title: "Highlights", keyPath: \.parametric.highlights)
        DevelopSlider(develop: develop, title: "Lights", keyPath: \.parametric.lights)
        DevelopSlider(develop: develop, title: "Darks", keyPath: \.parametric.darks)
        DevelopSlider(develop: develop, title: "Shadows", keyPath: \.parametric.shadows)
        Text("Point curve").font(.caption2).foregroundStyle(Theme.textTertiary).padding(.top, 4)
        Picker("", selection: $channel) { ForEach(Channel.allCases, id: \.self) { Text($0.rawValue) } }
            .pickerStyle(.segmented).labelsHidden()
        CurveEditor(points: Binding(get: { develop.recipe[keyPath: path] }, set: { develop.recipe[keyPath: path] = $0 }),
                    color: color, onCommit: { develop.commit() })
            .frame(height: 200)
            .accessibilityIdentifier("curve-editor")
        Text("Click to add a point, drag to move, double-click to remove.").font(.caption2).foregroundStyle(Theme.textTertiary)
    }

    private var path: WritableKeyPath<EditRecipe, [EditRecipe.CurvePoint]> {
        switch channel { case .rgb: \.curveRGB; case .red: \.curveRed; case .green: \.curveGreen; case .blue: \.curveBlue }
    }
    private var color: Color {
        switch channel { case .rgb: .white; case .red: .red; case .green: .green; case .blue: .blue }
    }
}

/// Point curve editor (monotone interpolation, like the renderer).
struct CurveEditor: View {
    @Binding var points: [EditRecipe.CurvePoint]
    var color: Color
    var onCommit: () -> Void
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Rectangle().fill(Theme.panelRaised)
                Path { p in
                    for f in [0.25, 0.5, 0.75] {
                        p.move(to: CGPoint(x: size.width * f, y: 0)); p.addLine(to: CGPoint(x: size.width * f, y: size.height))
                        p.move(to: CGPoint(x: 0, y: size.height * f)); p.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    }
                }.stroke(Theme.separator, lineWidth: 0.5)
                Path { p in
                    let curve = CurveSampler(points)
                    for i in 0...100 {
                        let x = Double(i) / 100
                        let pt = CGPoint(x: x * size.width, y: (1 - curve(x)) * size.height)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }.stroke(color, lineWidth: 1.5)
                ForEach(points.indices, id: \.self) { i in
                    Circle().fill(color).frame(width: 9, height: 9)
                        .position(x: points[i].x * size.width, y: (1 - points[i].y) * size.height)
                        .onTapGesture(count: 2) {
                            if i != 0 && i != points.count - 1 { points.remove(at: i); onCommit() }
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let x = min(1, max(0, v.location.x / size.width)), y = min(1, max(0, 1 - v.location.y / size.height))
                    if dragging == nil {
                        if let near = points.indices.min(by: { abs(points[$0].x - x) < abs(points[$1].x - x) }),
                           abs(points[near].x - x) < 0.04 {
                            dragging = near
                        } else {
                            points.append(.init(x, y))
                            points.sort { $0.x < $1.x }
                            dragging = points.firstIndex { $0.x == x }
                        }
                    }
                    guard let i = dragging else { return }
                    let lo = i > 0 ? points[i - 1].x + 0.01 : 0, hi = i < points.count - 1 ? points[i + 1].x - 0.01 : 1
                    points[i] = .init(i == 0 ? 0 : (i == points.count - 1 ? 1 : min(hi, max(lo, x))), y)
                }
                .onEnded { _ in dragging = nil; onCommit() })
        }
    }
}

/// Same monotone interpolation as the renderer, for drawing.
struct CurveSampler {
    let xs: [Double], ys: [Double], ms: [Double]
    init(_ points: [EditRecipe.CurvePoint]) {
        let s = points.sorted { $0.x < $1.x }
        xs = s.map(\.x); ys = s.map(\.y)
        let n = xs.count
        var d = [Double](repeating: 0, count: max(1, n - 1))
        for i in 0..<max(0, n - 1) { d[i] = (ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], 1e-6) }
        var m = [Double](repeating: 0, count: n)
        if n >= 2 {
            m[0] = d[0]; m[n - 1] = d[n - 2]
            for i in 1..<max(1, n - 1) where i < n - 1 { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        }
        ms = m
    }
    func callAsFunction(_ x: Double) -> Double {
        guard xs.count >= 2 else { return x }
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h, t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
        return min(1, max(0, y))
    }
}

struct MixerPanel: View {
    @ObservedObject var develop: DevelopModel
    enum Mode: String, CaseIterable { case hue = "Hue", saturation = "Saturation", luminance = "Luminance" }
    @State private var mode: Mode = .saturation

    var body: some View {
        Toggle("Black & White (V)", isOn: Binding(get: { develop.recipe.monochrome }, set: { v in develop.set { $0.monochrome = v } }))
            .accessibilityIdentifier("develop-bw")
        if develop.recipe.monochrome {
            Text("B&W mix").font(.caption2).foregroundStyle(Theme.textTertiary)
            ForEach(EditRecipe.ColorBand.allCases, id: \.self) { band in
                bandSlider(band, title: band.rawValue.capitalized,
                           get: { develop.recipe.bwMix[band] ?? 0 }, set: { r, v in r.bwMix[band] = v == 0 ? nil : v })
            }
        } else {
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden()
            ForEach(EditRecipe.ColorBand.allCases, id: \.self) { band in
                bandSlider(band, title: band.rawValue.capitalized, get: { value(band) }, set: { r, v in
                    var shift = r.hsl[band] ?? .init()
                    switch mode { case .hue: shift.hue = v; case .saturation: shift.saturation = v; case .luminance: shift.luminance = v }
                    r.hsl[band] = shift.isZero ? nil : shift
                })
            }
        }
    }

    private func value(_ band: EditRecipe.ColorBand) -> Double {
        let shift = develop.recipe.hsl[band] ?? .init()
        switch mode { case .hue: return shift.hue; case .saturation: return shift.saturation; case .luminance: return shift.luminance }
    }

    private func bandSlider(_ band: EditRecipe.ColorBand, title: String, get: @escaping () -> Double,
                            set: @escaping (inout EditRecipe, Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hue: band.hue / 360, saturation: 0.8, brightness: 0.9)).frame(width: 8, height: 8)
            Text(title).frame(width: 56, alignment: .leading).foregroundStyle(Theme.textSecondary)
                .onTapGesture(count: 2) { develop.set { set(&$0, 0) } }
            Slider(value: Binding(get: get, set: { v in set(&develop.recipe, v) }), in: -100...100, step: 1,
                   onEditingChanged: { if !$0 { develop.commit() } })
                .controlSize(.mini)
                .accessibilityIdentifier("hsl-\(band.rawValue)")
            Text(String(format: "%.0f", get())).monospacedDigit().frame(width: 28, alignment: .trailing)
                .foregroundStyle(get() == 0 ? Theme.textTertiary : Theme.text)
        }
    }
}

struct GradingPanel: View {
    @ObservedObject var develop: DevelopModel
    enum Region: String, CaseIterable { case shadows = "Shadows", midtones = "Midtones", highlights = "Highlights", global = "Global" }
    @State private var region: Region = .midtones

    var body: some View {
        Picker("", selection: $region) { ForEach(Region.allCases, id: \.self) { Text($0.rawValue) } }
            .pickerStyle(.segmented).labelsHidden()
        ColorWheel(hue: Binding(get: { develop.recipe[keyPath: path].hue }, set: { develop.recipe[keyPath: path].hue = $0 }),
                   saturation: Binding(get: { develop.recipe[keyPath: path].saturation }, set: { develop.recipe[keyPath: path].saturation = $0 }),
                   onCommit: { develop.commit() })
            .frame(width: 150, height: 150).frame(maxWidth: .infinity)
        DevelopSlider(develop: develop, title: "Hue", keyPath: path.appending(path: \.hue), range: 0...360,
                      track: [.red, .yellow, .green, .cyan, .blue, .purple, .red])
        DevelopSlider(develop: develop, title: "Saturation", keyPath: path.appending(path: \.saturation), range: 0...100)
        DevelopSlider(develop: develop, title: "Luminance", keyPath: path.appending(path: \.luminance))
        DevelopSlider(develop: develop, title: "Blending", keyPath: \.grading.blending, range: 0...100, defaultValue: 50)
        DevelopSlider(develop: develop, title: "Balance", keyPath: \.grading.balance)
    }

    private var path: WritableKeyPath<EditRecipe, EditRecipe.Wheel> {
        switch region {
        case .shadows: \.grading.shadows
        case .midtones: \.grading.midtones
        case .highlights: \.grading.highlights
        case .global: \.grading.global
        }
    }
}

/// Hue (angle) and saturation (distance) picker.
struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    var onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                Circle().fill(RadialGradient(colors: [.gray, .gray.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                let angle = hue * .pi / 180, dist = saturation / 100 * r
                Circle().stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                    .position(x: c.x + cos(angle) * dist, y: c.y - sin(angle) * dist)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = Double(v.location.x - c.x), dy = Double(c.y - v.location.y)
                    var a = atan2(dy, dx) * 180 / Double.pi
                    if a < 0 { a += 360 }
                    hue = a.rounded()
                    let distance = (dx * dx + dy * dy).squareRoot()
                    saturation = min(100, (distance / Double(r) * 100).rounded())
                }
                .onEnded { _ in onCommit() })
            .onTapGesture(count: 2) { saturation = 0; onCommit() }
        }
    }
}

struct DetailPanel: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        Text("Sharpening").font(.caption2).foregroundStyle(Theme.textTertiary)
        DevelopSlider(develop: develop, title: "Amount", keyPath: \.sharpenAmount, range: 0...150)
        DevelopSlider(develop: develop, title: "Radius", keyPath: \.sharpenRadius, range: 0.5...3, step: 0.1, format: "%.1f", defaultValue: 1)
        DevelopSlider(develop: develop, title: "Detail", keyPath: \.sharpenDetail, range: 0...100, defaultValue: 25)
        DevelopSlider(develop: develop, title: "Masking", keyPath: \.sharpenMasking, range: 0...100)
        Text("Noise reduction").font(.caption2).foregroundStyle(Theme.textTertiary).padding(.top, 4)
        DevelopSlider(develop: develop, title: "Luminance", keyPath: \.noiseLuminance, range: 0...100)
        DevelopSlider(develop: develop, title: "Colour", keyPath: \.noiseColor, range: 0...100)
    }
}

struct EffectsPanel: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        Text("Post-crop vignette").font(.caption2).foregroundStyle(Theme.textTertiary)
        DevelopSlider(develop: develop, title: "Amount", keyPath: \.vignetteAmount)
        DevelopSlider(develop: develop, title: "Midpoint", keyPath: \.vignetteMidpoint, range: 0...100, defaultValue: 50)
        DevelopSlider(develop: develop, title: "Roundness", keyPath: \.vignetteRoundness)
        DevelopSlider(develop: develop, title: "Feather", keyPath: \.vignetteFeather, range: 0...100, defaultValue: 50)
        Text("Grain").font(.caption2).foregroundStyle(Theme.textTertiary).padding(.top, 4)
        DevelopSlider(develop: develop, title: "Amount", keyPath: \.grainAmount, range: 0...100)
        DevelopSlider(develop: develop, title: "Size", keyPath: \.grainSize, range: 0...100, defaultValue: 25)
        DevelopSlider(develop: develop, title: "Roughness", keyPath: \.grainRoughness, range: 0...100, defaultValue: 50)
    }
}

struct SnapshotsPanel: View {
    @ObservedObject var develop: DevelopModel
    var body: some View {
        if develop.recipe.snapshots.isEmpty {
            Text("Save alternatives with ⋯ → New Snapshot.").foregroundStyle(Theme.textTertiary)
        }
        ForEach(develop.recipe.snapshots) { snapshot in
            HStack {
                Button(snapshot.name) { develop.apply(snapshot) }.buttonStyle(.link)
                Spacer()
                Text(snapshot.created.formatted(date: .omitted, time: .shortened)).foregroundStyle(Theme.textTertiary)
                Button { develop.set { $0.snapshots.removeAll { $0.id == snapshot.id } } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }
}
