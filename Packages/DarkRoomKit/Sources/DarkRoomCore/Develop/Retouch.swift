import Foundation

/// A healing / clone / remove spot. Coordinates like masks (normalised, after rotation/mirroring, before crop).
public struct RetouchSpot: Codable, Hashable, Sendable, Identifiable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Copy texture from the source, keep the destination's colour and light.
        case heal
        /// Copy the source exactly.
        case clone
        /// Fill from the best nearby area automatically (content-aware).
        case remove
    }
    public var id = UUID()
    public var mode: Mode
    public var center: [Double]
    /// Radius as a fraction of the image's long edge.
    public var radius: Double
    /// Source centre (nil = choose automatically).
    public var source: [Double]?
    public var feather: Double = 50
    public var opacity: Double = 100

    public init(mode: Mode, center: [Double], radius: Double, source: [Double]? = nil) {
        self.mode = mode; self.center = center; self.radius = radius; self.source = source
    }
}
