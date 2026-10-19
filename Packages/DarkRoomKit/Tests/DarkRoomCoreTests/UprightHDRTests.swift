import Foundation
import Testing
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import DarkRoomCore

@Suite("Develop: Upright, lens, transform and HDR")
struct UprightHDRTests {
    let engine = RenderEngine.shared

    /// Sky over ground with a horizon line, tilted by `degrees`.
    func horizon(tilt degrees: Double) -> CIImage {
        let size = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let sky = CIImage(color: CIColor(red: 0.45, green: 0.65, blue: 0.95)).cropped(to: CGRect(x: -600, y: 400, width: 2400, height: 1200))
        let ground = CIImage(color: CIColor(red: 0.25, green: 0.2, blue: 0.12)).cropped(to: CGRect(x: -600, y: -800, width: 2400, height: 1200))
        let scene = sky.composited(over: ground)
            .transformed(by: CGAffineTransform(translationX: -600, y: -400).concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
                .concatenating(CGAffineTransform(translationX: 600, y: 400)))
        return scene.cropped(to: size)
    }

    @Test func levelStraightensATiltedHorizon() throws {
        let tilted = horizon(tilt: 6)
        let (angle, _) = Upright.analyze(tilted, mode: .level)
        #expect(abs(angle) > 3, "Detects the tilt (\(angle))")
        var g = EditRecipe.Geometry(); g.straighten = angle
        let fixed = engine.applyGeometry(tilted, g)
        let (after, _) = Upright.analyze(fixed, mode: .level)
        #expect(abs(after) < 1.5, "Level after correction (\(after))")
    }

    /// White card with vertical black bars.
    func bars() -> CIImage {
        var image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        for x in stride(from: 100, through: 900, by: 100) {
            let bar = CIImage(color: .black).cropped(to: CGRect(x: x, y: 50, width: 14, height: 900))
            image = bar.composited(over: image)
        }
        return image
    }

    @Test func verticalReducesConvergingLines() throws {
        var t = EditRecipe.Transform(); t.vertical = 40
        let converging = engine.applyTransform(bars(), t)
        let (_, suggested) = Upright.analyze(converging, mode: .vertical)
        #expect(suggested.vertical != 0, "Detects convergence")
        let fixed = engine.applyTransform(converging, suggested)
        let (_, remaining) = Upright.analyze(fixed, mode: .vertical)
        #expect(abs(remaining.vertical) < abs(suggested.vertical) * 0.6, "Mostly corrected (\(suggested.vertical) → \(remaining.vertical))")
    }

    @Test func lensAndTransformProduceValidImages() {
        var r = EditRecipe()
        r.lens.distortion = 40; r.lens.vignetting = 30; r.lens.purpleFringe = 10
        r.geometry.transform.horizontal = 20; r.geometry.transform.rotate = 2; r.calibration.blueSaturation = 30
        let out = engine.render(bars(), recipe: r, isRAW: false)
        #expect(out.extent.width > 500 && out.extent.height > 500)
        #expect(out.extent.width <= 1000 && out.extent.height <= 1000, "Cropped to the area with pixels")
        #expect(engine.cgImage(out) != nil)
    }

    @Test func hdrKeepsHeadroomAndExportsAGainMap() throws {
        // A highlight at 3× SDR white.
        let bright = CIImage(color: CIColor(red: 3, green: 3, blue: 3, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = bright.composited(over: CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300)))
        var r = EditRecipe(); r.hdr = true; r.contrast = 20; r.vibrance = 10
        let out = engine.render(image, recipe: r, isRAW: false)
        let avg = out.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 20, y: 20, width: 60, height: 60))])
        var px = [Float](repeating: 0, count: 4)
        engine.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                              colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        #expect(px[1] > 1.5, "Highlight stays above SDR white (\(px[1]))")

        let dest = FileManager.default.temporaryDirectory.appending(path: "darkroom-hdr-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: dest) }
        let original = FileManager.default.temporaryDirectory.appending(path: "darkroom-hdr-src-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: original) }
        try engine.context.writeHEIFRepresentation(of: image.applyingFilter("CIColorClamp"), to: original, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        try engine.exportHDR(out, type: .heic, original: original, to: dest)
        let source = try #require(CGImageSourceCreateWithURL(dest as CFURL, nil))
        let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
            ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
        #expect(gainMap != nil, "HEIC carries a gain map")
    }
}
