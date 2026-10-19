import Foundation

/// Every Develop setting for one photo. Stored with the edited version in Immich's asset metadata
/// (key `darkroom.recipe`), so re-editing always starts from the original with every control in place.
///
/// Decoding is lenient: missing keys take their defaults, so recipes from older DarkRoom versions keep working.
public struct EditRecipe: Codable, Hashable, Sendable {
    public static let metadataKey = "darkroom.recipe"
    public static let currentSchema = 1

    public var schema = EditRecipe.currentSchema

    // Profile (look applied on top of the RAW/colour rendering)
    public var profile: Profile = .standard
    public var profileAmount: Double = 100            // 0…200 %

    // RAW engine
    public var raw = RawSettings()

    // White balance
    public var whiteBalance: WhiteBalance = .asShot
    /// Kelvin for RAW; for other files a relative shift (-100…100) where 0 is "as shot".
    public var temperature: Double = 0
    public var tint: Double = 0                       // -150…150
    /// Eyedropper sample (normalised x, y from top-left) for custom white balance.
    public var neutralPoint: [Double]?

    // Basic tone (-100…100 unless noted)
    public var exposure: Double = 0                   // stops, -5…5
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0

    // Presence
    public var texture: Double = 0
    public var clarity: Double = 0
    public var dehaze: Double = 0
    public var vibrance: Double = 0
    public var saturation: Double = 0

    // Tone curve
    public var parametric = ParametricCurve()
    public var curveRGB: [CurvePoint] = CurvePoint.identity
    public var curveRed: [CurvePoint] = CurvePoint.identity
    public var curveGreen: [CurvePoint] = CurvePoint.identity
    public var curveBlue: [CurvePoint] = CurvePoint.identity

    // Colour mixer
    public var hsl: [ColorBand: HSLShift] = [:]
    public var monochrome = false
    public var bwMix: [ColorBand: Double] = [:]       // -100…100 per band

    // Colour grading
    public var grading = ColorGrading()

    // Detail
    public var sharpenAmount: Double = 0              // 0…150
    public var sharpenRadius: Double = 1.0            // 0.5…3
    public var sharpenDetail: Double = 25             // 0…100
    public var sharpenMasking: Double = 0             // 0…100
    public var noiseLuminance: Double = 0             // 0…100
    public var noiseColor: Double = 0                 // 0…100 (RAW default 25 is applied by the engine)

    // Effects
    public var vignetteAmount: Double = 0             // -100…100
    public var vignetteMidpoint: Double = 50
    public var vignetteRoundness: Double = 0
    public var vignetteFeather: Double = 50
    public var grainAmount: Double = 0
    public var grainSize: Double = 25
    public var grainRoughness: Double = 50

    // Geometry
    public var geometry = Geometry()

    // Named alternatives kept inside the recipe.
    public var snapshots: [Snapshot] = []

    public init() {}

    /// True when nothing has been changed (an untouched photo needs no version).
    public var isIdentity: Bool { withoutSnapshots == EditRecipe().withoutSnapshots }

    /// True when the only changes are 90° rotation, mirroring and crop: Immich's built-in edit can do those
    /// for regular stills without creating a version.
    public var isGeometryOnlyBuiltIn: Bool {
        var adjustments = withoutSnapshots
        adjustments.geometry = Geometry()
        return adjustments == EditRecipe().withoutSnapshots && geometry.straighten == 0 && geometry.transform == .identity
    }

    var withoutSnapshots: EditRecipe { var r = self; r.snapshots = []; return r }

    // MARK: Nested types

    public enum Profile: String, Codable, CaseIterable, Sendable {
        case standard, neutral, vivid, landscape, portrait, monochrome, linear
        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    public enum WhiteBalance: String, Codable, CaseIterable, Sendable {
        case asShot, auto, daylight, cloudy, shade, tungsten, fluorescent, flash, custom
        public var title: String {
            switch self {
            case .asShot: "As Shot"
            default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }
        /// Kelvin / tint for presets (RAW).
        public var preset: (kelvin: Double, tint: Double)? {
            switch self {
            case .daylight: (5500, 10)
            case .cloudy: (6500, 10)
            case .shade: (7500, 10)
            case .tungsten: (2850, 0)
            case .fluorescent: (3800, 21)
            case .flash: (5500, 0)
            default: nil
            }
        }
    }

    public struct RawSettings: Codable, Hashable, Sendable {
        /// Apple's "boost" (default tone curve strength), 0…1.
        public var boost: Double = 1
        public var boostShadows: Double = 1
        public var localToneMapping: Double = 0.5
        public var shadowBias: Double = 0
        public var extendedDynamicRange: Double = 0
        public var moireReduction: Double = 0
        public var lensCorrection = true
        public init() {}
    }

    public enum ColorBand: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
        /// Centre hue in degrees.
        public var hue: Double {
            switch self {
            case .red: 0
            case .orange: 30
            case .yellow: 60
            case .green: 120
            case .aqua: 180
            case .blue: 225
            case .purple: 270
            case .magenta: 315
            }
        }
    }

    public struct HSLShift: Codable, Hashable, Sendable {
        public var hue: Double = 0          // -100…100
        public var saturation: Double = 0
        public var luminance: Double = 0
        public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
            self.hue = hue; self.saturation = saturation; self.luminance = luminance
        }
        public var isZero: Bool { hue == 0 && saturation == 0 && luminance == 0 }
    }

    public struct ParametricCurve: Codable, Hashable, Sendable {
        public var highlights: Double = 0   // -100…100
        public var lights: Double = 0
        public var darks: Double = 0
        public var shadows: Double = 0
        public var split1: Double = 25      // region boundaries, 0…100
        public var split2: Double = 50
        public var split3: Double = 75
        public init() {}
    }

    public struct CurvePoint: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
        public static let identity = [CurvePoint(0, 0), CurvePoint(1, 1)]
    }

    public struct Wheel: Codable, Hashable, Sendable {
        public var hue: Double = 0          // degrees
        public var saturation: Double = 0   // 0…100
        public var luminance: Double = 0   // -100…100
        public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
            self.hue = hue; self.saturation = saturation; self.luminance = luminance
        }
    }

    public struct ColorGrading: Codable, Hashable, Sendable {
        public var shadows = Wheel()
        public var midtones = Wheel()
        public var highlights = Wheel()
        public var global = Wheel()
        public var blending: Double = 50
        public var balance: Double = 0
        public init() {}
    }

    public struct Geometry: Codable, Hashable, Sendable {
        /// Normalised crop in the rotated/mirrored image (origin top-left), nil = no crop.
        public var crop: CropRect?
        /// Fine rotation in degrees, -45…45.
        public var straighten: Double = 0
        /// Quarter turns clockwise, 0…3.
        public var quarterTurns: Int = 0
        public var flipHorizontal = false
        public var flipVertical = false
        public var aspect: Aspect = .free
        public var transform = Transform.identity
        public init() {}
    }

    public struct CropRect: Codable, Hashable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)
    }

    public enum Aspect: String, Codable, CaseIterable, Sendable {
        case free, original, square = "1:1", fourFive = "4:5", threeTwo = "3:2", sixteenNine = "16:9", fiveSeven = "5:7"
        public func ratio(original: Double) -> Double? {
            switch self {
            case .free: nil
            case .original: original
            case .square: 1
            case .fourFive: 4.0 / 5
            case .threeTwo: 3.0 / 2
            case .sixteenNine: 16.0 / 9
            case .fiveSeven: 5.0 / 7
            }
        }
    }

    /// Perspective transform (M4c), kept here so recipes are stable.
    public struct Transform: Codable, Hashable, Sendable {
        public var vertical: Double = 0
        public var horizontal: Double = 0
        public var rotate: Double = 0
        public var aspect: Double = 0
        public var scale: Double = 100
        public static let identity = Transform()
    }

    public struct Snapshot: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var name: String
        public var created = Date()
        public var recipe: Data   // encoded EditRecipe without snapshots
        public init(name: String, recipe: EditRecipe) {
            self.name = name
            self.recipe = (try? JSONEncoder().encode(recipe.withoutSnapshots)) ?? Data()
        }
    }
}

// MARK: Lenient decoding

extension EditRecipe {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        func get<T: Decodable>(_ key: String, _ target: inout T) {
            if let value = try? c.decodeIfPresent(T.self, forKey: AnyKey(key)) { target = value }
        }
        get("schema", &schema); get("profile", &profile); get("profileAmount", &profileAmount); get("raw", &raw)
        get("whiteBalance", &whiteBalance); get("temperature", &temperature); get("tint", &tint); get("neutralPoint", &neutralPoint)
        get("exposure", &exposure); get("contrast", &contrast); get("highlights", &highlights); get("shadows", &shadows)
        get("whites", &whites); get("blacks", &blacks); get("texture", &texture); get("clarity", &clarity)
        get("dehaze", &dehaze); get("vibrance", &vibrance); get("saturation", &saturation)
        get("parametric", &parametric); get("curveRGB", &curveRGB); get("curveRed", &curveRed)
        get("curveGreen", &curveGreen); get("curveBlue", &curveBlue); get("hsl", &hsl); get("monochrome", &monochrome)
        get("bwMix", &bwMix); get("grading", &grading); get("sharpenAmount", &sharpenAmount)
        get("sharpenRadius", &sharpenRadius); get("sharpenDetail", &sharpenDetail); get("sharpenMasking", &sharpenMasking)
        get("noiseLuminance", &noiseLuminance); get("noiseColor", &noiseColor); get("vignetteAmount", &vignetteAmount)
        get("vignetteMidpoint", &vignetteMidpoint); get("vignetteRoundness", &vignetteRoundness)
        get("vignetteFeather", &vignetteFeather); get("grainAmount", &grainAmount); get("grainSize", &grainSize)
        get("grainRoughness", &grainRoughness); get("geometry", &geometry); get("snapshots", &snapshots)
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

extension EditRecipe.RawSettings {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EditRecipe.AnyKey.self)
        func get<T: Decodable>(_ key: String, _ target: inout T) {
            if let value = try? c.decodeIfPresent(T.self, forKey: EditRecipe.AnyKey(key)) { target = value }
        }
        get("boost", &boost); get("boostShadows", &boostShadows); get("localToneMapping", &localToneMapping)
        get("shadowBias", &shadowBias); get("extendedDynamicRange", &extendedDynamicRange)
        get("moireReduction", &moireReduction); get("lensCorrection", &lensCorrection)
    }
}

extension EditRecipe.Geometry {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EditRecipe.AnyKey.self)
        func get<T: Decodable>(_ key: String, _ target: inout T) {
            if let value = try? c.decodeIfPresent(T.self, forKey: EditRecipe.AnyKey(key)) { target = value }
        }
        get("crop", &crop); get("straighten", &straighten); get("quarterTurns", &quarterTurns)
        get("flipHorizontal", &flipHorizontal); get("flipVertical", &flipVertical); get("aspect", &aspect)
        get("transform", &transform)
    }
}
