import Foundation

/// A local adjustment: a mask (built from components) and the adjustments applied through it.
/// Coordinates are normalised (0…1, top-left origin) in the photo after 90° rotation and mirroring, but before
/// straighten and crop, so masks stay attached to the picture when the crop changes.
public struct Mask: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var components: [MaskComponent]
    public var inverted = false
    public var isEnabled = true
    public var adjust = LocalAdjustments()

    public init(name: String, components: [MaskComponent], adjust: LocalAdjustments = LocalAdjustments()) {
        self.name = name
        self.components = components
        self.adjust = adjust
    }

    /// AI masks need Apple Vision on the source image.
    public var usesVision: Bool { components.contains { $0.kind.isVision } }
}

public struct MaskComponent: Codable, Hashable, Sendable, Identifiable {
    public enum Operation: String, Codable, CaseIterable, Sendable { case add, subtract, intersect }
    public var id = UUID()
    public var operation: Operation = .add
    public var kind: MaskKind

    public init(_ kind: MaskKind, operation: Operation = .add) {
        self.kind = kind
        self.operation = operation
    }
}

public enum MaskKind: Codable, Hashable, Sendable {
    /// Full effect at `start`, fading to none at `end`.
    case linear(start: [Double], end: [Double])
    /// Ellipse: centre, radii (fractions of width/height), rotation (degrees), feather 0…100, effect inside or outside.
    case radial(center: [Double], radius: [Double], angle: Double, feather: Double, inside: Bool)
    case brush(strokes: [BrushStroke])
    /// Apple Vision: the main subject(s).
    case subject
    /// Apple Vision: people (person segmentation).
    case people
    /// Sky (bright, blue or neutral, upper, smooth regions).
    case sky
    /// Everything that isn't the subject.
    case background
    /// Colours near a sampled hue/saturation; `range` 0…100.
    case colorRange(hue: Double, saturation: Double, range: Double)
    /// Luminance between `low` and `high` (0…1) with soft edges.
    case luminanceRange(low: Double, high: Double, smoothness: Double)
    /// iPhone portrait depth (0 = near, 1 = far) between `near` and `far`.
    case depthRange(near: Double, far: Double, smoothness: Double)

    public var isVision: Bool {
        switch self { case .subject, .people, .background: true; default: false }
    }

    public var title: String {
        switch self {
        case .linear: "Linear Gradient"
        case .radial: "Radial Gradient"
        case .brush: "Brush"
        case .subject: "Subject"
        case .people: "People"
        case .sky: "Sky"
        case .background: "Background"
        case .colorRange: "Colour Range"
        case .luminanceRange: "Luminance Range"
        case .depthRange: "Depth Range"
        }
    }
}

public struct BrushStroke: Codable, Hashable, Sendable {
    /// Normalised points along the stroke.
    public var points: [[Double]]
    /// Brush diameter as a fraction of the image's long edge.
    public var size: Double
    /// 0…100: softness of the brush edge.
    public var feather: Double
    /// 0…100: how much each pass adds.
    public var flow: Double
    public var erase: Bool

    public init(points: [[Double]], size: Double, feather: Double = 50, flow: Double = 100, erase: Bool = false) {
        self.points = points; self.size = size; self.feather = feather; self.flow = flow; self.erase = erase
    }
}

/// What a mask changes (-100…100 unless noted; exposure in stops).
public struct LocalAdjustments: Codable, Hashable, Sendable {
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    public var temperature: Double = 0
    public var tint: Double = 0
    public var hue: Double = 0          // degrees -180…180
    public var saturation: Double = 0
    public var texture: Double = 0
    public var clarity: Double = 0
    public var dehaze: Double = 0
    public var sharpness: Double = 0
    public var noise: Double = 0        // 0…100 smoothing
    /// Colour overlay (like Lightroom's Color swatch): hue in degrees, strength 0…100.
    public var overlayHue: Double = 0
    public var overlayStrength: Double = 0

    public init() {}
    public var isIdentity: Bool { self == LocalAdjustments() }
}

extension EditRecipe {
    /// Masks applied after the global adjustments.
    public var hasMasks: Bool { masks.contains { $0.isEnabled && !$0.components.isEmpty && !$0.adjust.isIdentity } }
}
