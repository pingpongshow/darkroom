import Foundation

/// A Develop preset: some (or all) groups of a recipe, a name and a folder.
public struct Preset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var folder: String
    public var groups: Set<RecipeGroup>
    public var recipe: EditRecipe
    public var isBuiltIn: Bool
    /// Safe for Live Photo motion and video (no grain or vignette).
    public var videoSafe: Bool

    public init(id: UUID = UUID(), name: String, folder: String, groups: Set<RecipeGroup>? = nil, recipe: EditRecipe,
                isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.folder = folder
        self.groups = groups ?? RecipeGroup.changed(in: recipe).intersection(RecipeGroup.looks)
        self.recipe = recipe
        self.isBuiltIn = isBuiltIn
        self.videoSafe = recipe.grainAmount == 0 && recipe.vignetteAmount == 0
    }

    /// Applies the preset to a recipe at `amount` (0…2).
    public func apply(to recipe: EditRecipe, amount: Double = 1) -> EditRecipe {
        recipe.applying(self.recipe, groups: groups, amount: amount)
    }
}

/// A shareable `.darkroom-preset` file (one preset, a folder, or everything). Human-readable JSON.
public struct PresetFile: Codable, Sendable {
    public static let fileExtension = "darkroom-preset"
    public var format = "darkroom-preset"
    public var version = 1
    public var presets: [Preset]
    public var luts: [LUT]

    public init(presets: [Preset], luts: [LUT] = []) {
        self.presets = presets.map { var p = $0; p.isBuiltIn = false; return p }
        self.luts = luts
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The user's presets on this Mac (built-ins + their own), favourites, shortcuts, recents and camera defaults.
public final class PresetStore: @unchecked Sendable {
    public struct State: Codable, Sendable {
        public var presets: [Preset] = []
        public var favorites: [UUID] = []
        /// ⌃1…⌃9 → preset.
        public var shortcuts: [Int: UUID] = [:]
        public var recent: [UUID] = []
        /// "Make Model" or "lens:<Lens>" → preset.
        public var cameraDefaults: [String: UUID] = [:]
        public var autoApplyCameraDefaults = false
        public var hiddenBuiltIns: Set<UUID> = []
    }

    private let file: URL
    private let lock = NSLock()
    private var state: State

    public init(file: URL) {
        self.file = file
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: file))) ?? State()
    }

    public var snapshot: State { lock.withLock { state } }

    public var all: [Preset] {
        let s = snapshot
        return BuiltInPresets.all.filter { !s.hiddenBuiltIns.contains($0.id) } + s.presets
    }

    public func preset(_ id: UUID) -> Preset? { all.first { $0.id == id } }

    public var folders: [String] {
        var seen: [String] = []
        for p in all where !seen.contains(p.folder) { seen.append(p.folder) }
        return seen
    }

    public func update(_ change: (inout State) -> Void) {
        lock.withLock { change(&state) }
        persist()
    }

    public func save(_ preset: Preset) {
        update { s in
            if let i = s.presets.firstIndex(where: { $0.id == preset.id }) { s.presets[i] = preset } else { s.presets.append(preset) }
        }
    }

    public func delete(_ id: UUID) {
        update { s in
            if BuiltInPresets.all.contains(where: { $0.id == id }) { s.hiddenBuiltIns.insert(id) }
            s.presets.removeAll { $0.id == id }
            s.favorites.removeAll { $0 == id }
            s.recent.removeAll { $0 == id }
            s.shortcuts = s.shortcuts.filter { $0.value != id }
            s.cameraDefaults = s.cameraDefaults.filter { $0.value != id }
        }
    }

    public func duplicate(_ preset: Preset) -> Preset {
        var copy = preset
        copy.id = UUID()
        copy.name = preset.name + " copy"
        copy.isBuiltIn = false
        if preset.isBuiltIn { copy.folder = "My Presets" }
        save(copy)
        return copy
    }

    public func toggleFavorite(_ id: UUID) {
        update { s in if s.favorites.contains(id) { s.favorites.removeAll { $0 == id } } else { s.favorites.append(id) } }
    }

    public func noteUsed(_ id: UUID) {
        update { s in s.recent.removeAll { $0 == id }; s.recent.insert(id, at: 0); s.recent = Array(s.recent.prefix(8)) }
    }

    public func setShortcut(_ number: Int?, for id: UUID) {
        update { s in
            s.shortcuts = s.shortcuts.filter { $0.value != id }
            if let number { s.shortcuts[number] = id }
        }
    }

    /// The camera default for an asset (lens default wins over body default).
    public func cameraDefault(make: String?, model: String?, lens: String?) -> Preset? {
        let s = snapshot
        if let lens, let id = s.cameraDefaults["lens:\(lens)"], let p = preset(id) { return p }
        if let key = Self.cameraKey(make: make, model: model), let id = s.cameraDefaults[key], let p = preset(id) { return p }
        return nil
    }

    public static func cameraKey(make: String?, model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        let make = make ?? ""
        return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)".trimmingCharacters(in: .whitespaces)
    }

    // MARK: Import / export

    public func export(_ presets: [Preset]) throws -> Data {
        let luts = Set(presets.compactMap(\.recipe.lutProfile)).compactMap { LUTLibrary.shared.lut($0) }.filter { !$0.id.hasPrefix("builtin.") }
        return try PresetFile(presets: presets, luts: luts).encoded()
    }

    /// Imports a `.darkroom-preset`, Lightroom `.xmp` or `.cube` file. Returns the imported presets and a
    /// report of anything that couldn't be carried over.
    @discardableResult
    public func importFile(_ url: URL) throws -> (presets: [Preset], report: [String]) {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case PresetFile.fileExtension:
            let file = try JSONDecoder().decode(PresetFile.self, from: data)
            for lut in file.luts { try LUTLibrary.shared.add(lut) }
            let imported = file.presets.map { p -> Preset in
                var copy = p
                copy.id = UUID()
                copy.isBuiltIn = false
                copy.folder = p.folder == "My Presets" || p.folder.isEmpty ? "Imported" : "Imported/\(p.folder)"
                return copy
            }
            update { s in s.presets += imported }
            return (imported, [])
        case "xmp", "lrtemplate":
            let (recipe, report, name) = try LightroomXMP.parse(data, fallbackName: url.deletingPathExtension().lastPathComponent)
            let preset = Preset(name: name, folder: "Imported", recipe: recipe)
            save(preset)
            return ([preset], report)
        case "cube":
            let text = String(decoding: data, as: UTF8.self)
            let name = url.deletingPathExtension().lastPathComponent
            let lut = try LUT.parseCube(text, id: "user.\(UUID().uuidString)", name: name)
            try LUTLibrary.shared.add(lut)
            var recipe = EditRecipe()
            recipe.lutProfile = lut.id
            let preset = Preset(name: name, folder: "Imported", groups: [.profile], recipe: recipe)
            save(preset)
            return ([preset], [])
        default:
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    private func persist() {
        let s = snapshot
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: file, options: .atomic)
    }
}

// MARK: Lightroom XMP

/// Maps Lightroom/Camera Raw `crs:` settings onto DarkRoom's recipe.
public enum LightroomXMP {
    public static func parse(_ data: Data, fallbackName: String) throws -> (EditRecipe, [String], String) {
        let parser = XMLParser(data: data)
        let collector = Collector()
        parser.delegate = collector
        guard parser.parse() || !collector.values.isEmpty else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        let v = collector.values
        var r = EditRecipe()
        var used = Set<String>()
        func num(_ key: String) -> Double? {
            guard let s = v[key] else { return nil }
            used.insert(key)
            return Double(s.replacingOccurrences(of: "+", with: ""))
        }
        func set(_ key: String, _ path: WritableKeyPath<EditRecipe, Double>, scale: Double = 1) {
            if let n = num(key) { r[keyPath: path] = n * scale }
        }
        set("Exposure2012", \.exposure); set("Contrast2012", \.contrast); set("Highlights2012", \.highlights)
        set("Shadows2012", \.shadows); set("Whites2012", \.whites); set("Blacks2012", \.blacks)
        set("Texture", \.texture); set("Clarity2012", \.clarity); set("Dehaze", \.dehaze)
        set("Vibrance", \.vibrance); set("Saturation", \.saturation)
        set("Sharpness", \.sharpenAmount); set("SharpenRadius", \.sharpenRadius); set("SharpenDetail", \.sharpenDetail)
        set("SharpenEdgeMasking", \.sharpenMasking); set("LuminanceSmoothing", \.noiseLuminance); set("ColorNoiseReduction", \.noiseColor)
        set("PostCropVignetteAmount", \.vignetteAmount); set("PostCropVignetteMidpoint", \.vignetteMidpoint)
        set("PostCropVignetteRoundness", \.vignetteRoundness); set("PostCropVignetteFeather", \.vignetteFeather)
        set("GrainAmount", \.grainAmount); set("GrainSize", \.grainSize); set("GrainFrequency", \.grainRoughness)
        set("ParametricShadows", \.parametric.shadows); set("ParametricDarks", \.parametric.darks)
        set("ParametricLights", \.parametric.lights); set("ParametricHighlights", \.parametric.highlights)
        set("ParametricShadowSplit", \.parametric.split1); set("ParametricMidtoneSplit", \.parametric.split2)
        set("ParametricHighlightSplit", \.parametric.split3)
        // White balance: Lightroom stores absolute Kelvin for RAW and -100…100 for rendered files; "Temperature"
        // in presets is usually Kelvin with WhiteBalance=Custom. Incremental values map directly.
        if let t = num("IncrementalTemperature") { r.temperature = t }
        if let t = num("IncrementalTint") { r.tint = t }
        if let t = num("Temperature") { r.temperature = t; r.whiteBalance = .custom }
        if let t = num("Tint"), r.tint == 0 { r.tint = t }
        if let wb = v["WhiteBalance"] {
            used.insert("WhiteBalance")
            r.whiteBalance = EditRecipe.WhiteBalance.allCases.first { $0.title.lowercased() == wb.lowercased() } ?? r.whiteBalance
        }
        if v["ConvertToGrayscale"]?.lowercased() == "true" { r.monochrome = true; used.insert("ConvertToGrayscale") }
        let bandNames: [(String, EditRecipe.ColorBand)] = [("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
                                                           ("Aqua", .aqua), ("Blue", .blue), ("Purple", .purple), ("Magenta", .magenta)]
        for (name, band) in bandNames {
            let shift = EditRecipe.HSLShift(hue: num("HueAdjustment\(name)") ?? 0, saturation: num("SaturationAdjustment\(name)") ?? 0,
                                           luminance: num("LuminanceAdjustment\(name)") ?? 0)
            if !shift.isZero { r.hsl[band] = shift }
            if let mix = num("GrayMixer\(name)"), mix != 0 { r.bwMix[band] = mix }
        }
        func wheel(_ prefix: String) -> EditRecipe.Wheel? {
            let h = num("ColorGrade\(prefix)Hue"), s = num("ColorGrade\(prefix)Sat"), l = num("ColorGrade\(prefix)Lum")
            guard h != nil || s != nil || l != nil else { return nil }
            return .init(hue: h ?? 0, saturation: s ?? 0, luminance: l ?? 0)
        }
        if let w = wheel("Shadow") { r.grading.shadows = w }
        if let w = wheel("Midtone") { r.grading.midtones = w }
        if let w = wheel("Highlight") { r.grading.highlights = w }
        if let w = wheel("Global") { r.grading.global = w }
        if let b = num("ColorGradeBlending") { r.grading.blending = b }
        if let b = num("SplitToningBalance") { r.grading.balance = b }
        if r.grading.shadows.saturation == 0, let h = num("SplitToningShadowHue"), let s = num("SplitToningShadowSaturation") {
            r.grading.shadows = .init(hue: h, saturation: s)
        }
        if r.grading.highlights.saturation == 0, let h = num("SplitToningHighlightHue"), let s = num("SplitToningHighlightSaturation") {
            r.grading.highlights = .init(hue: h, saturation: s)
        }
        func curve(_ key: String) -> [EditRecipe.CurvePoint]? {
            guard let points = collector.sequences[key], points.count >= 2 else { return nil }
            used.insert(key)
            let parsed = points.compactMap { p -> EditRecipe.CurvePoint? in
                let xy = p.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return xy.count == 2 ? .init(xy[0] / 255, xy[1] / 255) : nil
            }
            return parsed.count >= 2 && parsed != EditRecipe.CurvePoint.identity ? parsed : nil
        }
        if let c = curve("ToneCurvePV2012") { r.curveRGB = c }
        if let c = curve("ToneCurvePV2012Red") { r.curveRed = c }
        if let c = curve("ToneCurvePV2012Green") { r.curveGreen = c }
        if let c = curve("ToneCurvePV2012Blue") { r.curveBlue = c }

        let ignorable: Set<String> = ["Version", "ProcessVersion", "PresetType", "Cluster", "UUID", "SupportsAmount", "SupportsAmount2",
                                      "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange", "SupportsNormalDynamicRange",
                                      "SupportsSceneReferred", "SupportsOutputReferred", "RequiresRGBTables", "CameraModelRestriction",
                                      "Copyright", "ContactInfo", "HasSettings", "AlreadyApplied", "Name", "ShortName", "SortName", "Group",
                                      "Description", "Amount"]
        let unsupported = v.keys.filter { !used.contains($0) && !ignorable.contains($0) && !$0.hasPrefix("Supports") }
            .filter { key in
                // Only report settings that actually change something.
                guard let value = v[key] else { return false }
                return !["0", "+0", "0.0", "false", ""].contains(value)
            }
            .sorted()
        var report: [String] = []
        if !unsupported.isEmpty { report.append("Not carried over: " + unsupported.joined(separator: ", ")) }
        if !collector.masks.isEmpty { report.append("Masks (\(collector.masks.count)) aren’t imported yet") }
        let name = collector.name ?? fallbackName
        return (r, report, name)
    }

    final class Collector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var sequences: [String: [String]] = [:]
        var masks: [String] = []
        var name: String?
        private var currentSeq: String?
        private var inLi = false
        private var text = ""
        private var inName = false

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            for (key, value) in attributes where key.hasPrefix("crs:") {
                values[String(key.dropFirst(4))] = value
            }
            if element.hasPrefix("crs:") {
                let key = String(element.dropFirst(4))
                if key.hasPrefix("ToneCurvePV2012") { currentSeq = key; sequences[key] = [] }
                if key.hasPrefix("MaskGroupBasedCorrections") || key == "CircularGradientBasedCorrections" || key == "GradientBasedCorrections" {
                    masks.append(key)
                }
                if key == "Name" { inName = true }
            }
            if element == "rdf:li" { inLi = true; text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inLi { text += string } }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "rdf:li" {
                inLi = false
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let seq = currentSeq { sequences[seq, default: []].append(value) }
                else if inName, name == nil, !value.isEmpty { name = value }
            }
            if element.hasPrefix("crs:ToneCurvePV2012") { currentSeq = nil }
            if element == "crs:Name" { inName = false }
        }
    }
}
