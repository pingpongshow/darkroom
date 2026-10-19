import Foundation
import CoreImage
import Vision

/// Automatic Upright (Lightroom-style): Level from the horizon, Vertical from converging verticals.
public enum Upright {
    public enum Mode: String, CaseIterable, Sendable { case level = "Level", vertical = "Vertical", auto = "Auto" }

    /// Suggested geometry for `image` (already rotated/mirrored). Returns straighten degrees and transform.
    public static func analyze(_ image: CIImage, mode: Mode, engine: RenderEngine = .shared) -> (straighten: Double, transform: EditRecipe.Transform) {
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = engine.context.createCGImage(small, from: small.extent) else { return (0, .identity) }
        var straighten = 0.0
        var transform = EditRecipe.Transform.identity
        if mode != .vertical, let angle = horizonAngle(cg) { straighten = angle }
        if mode != .level, let v = verticalKeystone(cg) { transform.vertical = v }
        return (straighten, transform)
    }

    /// Degrees to straighten by (positive rotates the picture clockwise), from Vision's horizon.
    static func horizonAngle(_ cg: CGImage) -> Double? {
        let request = VNDetectHorizonRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        guard let horizon = request.results?.first else { return nil }
        let degrees = Double(horizon.angle) * 180 / .pi
        return abs(degrees) < 0.05 ? nil : max(-45, min(45, degrees))
    }

    /// Vertical keystone (-100…100) that makes near-vertical lines parallel.
    static func verticalKeystone(_ cg: CGImage) -> Double? {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.5
        request.maximumImageDimension = 1024
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        guard let observation = request.results?.first else { return nil }
        // Near-vertical segments: x position and lean (dx/dy; positive = top leans right).
        var samples: [(x: Double, lean: Double, weight: Double)] = []
        for contour in observation.topLevelContours + observation.topLevelContours.flatMap(\.childContours) {
            guard let simple = try? contour.polygonApproximation(epsilon: 0.004) else { continue }
            let pts = simple.normalizedPoints
            for (a, b) in zip(pts, pts.dropFirst()) {
                let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
                let length = hypot(dx, dy)
                guard length > 0.12, abs(dy) > abs(dx) * 3 else { continue }   // long and within ~18° of vertical
                let lean = dy > 0 ? dx / dy : -dx / -dy
                samples.append((x: Double(a.x + b.x) / 2, lean: lean, weight: length))
            }
        }
        guard samples.count >= 2 else { return nil }
        // Fit lean ≈ k·(x − 0.5): converging verticals (top narrower) give k < 0.
        var num = 0.0, den = 0.0
        for s in samples { let dx = s.x - 0.5; num += s.weight * dx * s.lean; den += s.weight * dx * dx }
        guard den > 1e-6 else { return nil }
        let k = num / den
        // Calibrated against DarkRoom's own transform (see UprightTests).
        let vertical = max(-100, min(100, k * 260))
        return abs(vertical) < 2 ? nil : vertical
    }
}
