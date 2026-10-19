import Foundation
import Testing
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import DarkRoomCore

@Suite("Develop: colour maths")
struct ColorMathTests {
    func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 0.004) -> Bool { simd_length(a - b) < tol }

    @Test func identityRecipeChangesNothing() {
        let t = ColorTransform(EditRecipe())
        #expect(t.isIdentity)
        for c in [SIMD3<Float>(0.1, 0.5, 0.9), SIMD3(0.7, 0.2, 0.3), SIMD3(0.5, 0.5, 0.5)] { #expect(near(t.apply(c), c)) }
    }

    @Test func contrastIsAMonotoneSCurve() {
        var r = EditRecipe(); r.contrast = 80
        let t = ColorTransform(r)
        #expect(t.tone(0.2) < 0.2)
        #expect(t.tone(0.8) > 0.8)
        #expect(abs(t.tone(0.5) - 0.5) < 0.001)
        var last: Float = -1
        for i in 0...100 { let y = t.tone(Float(i) / 100); #expect(y >= last); last = y }
    }

    @Test func pointCurveIsMonotoneAndHitsPoints() {
        let curve = MonotoneCurve([.init(0, 0), .init(0.25, 0.15), .init(0.5, 0.5), .init(0.75, 0.9), .init(1, 1)])
        #expect(abs(curve(0.25) - 0.15) < 0.001)
        var last: Float = -1
        for i in 0...200 { let y = curve(Float(i) / 200); #expect(y >= last - 1e-5); last = y }
    }

    @Test func hslTargetsOnlyItsBand() {
        var r = EditRecipe(); r.hsl[.blue] = .init(saturation: -100)
        let t = ColorTransform(r)
        let blue = t.apply(SIMD3(0.1, 0.2, 0.9))
        #expect(abs(blue.x - blue.z) < 0.08, "Blue becomes (almost) grey; bands blend smoothly")
        let red = SIMD3<Float>(0.9, 0.1, 0.1)
        #expect(near(t.apply(red), red, 0.01), "Red untouched")
    }

    @Test func monochromeAndGrading() {
        var mono = EditRecipe(); mono.monochrome = true
        let g = ColorTransform(mono).apply(SIMD3(0.8, 0.3, 0.1))
        #expect(abs(g.x - g.y) < 1e-4 && abs(g.y - g.z) < 1e-4)

        var warm = EditRecipe(); warm.grading.shadows = .init(hue: 30, saturation: 100)
        let dark = ColorTransform(warm).apply(SIMD3(0.15, 0.15, 0.15))
        #expect(dark.x > dark.z + 0.02, "Shadows tinted orange")
        let bright = ColorTransform(warm).apply(SIMD3(0.9, 0.9, 0.9))
        #expect(abs(bright.x - bright.z) < dark.x - dark.z, "Highlights barely affected")
    }

    @Test func recipeDecodesOldAndPartialJSON() throws {
        let json = #"{"schema":1,"exposure":0.5,"hsl":{"blue":{"hue":0,"saturation":-20,"luminance":0}},"futureKey":42}"#
        let r = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(r.exposure == 0.5)
        #expect(r.hsl[.blue]?.saturation == -20)
        #expect(r.contrast == 0)
        var crop = EditRecipe(); crop.geometry.quarterTurns = 1; crop.geometry.crop = .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        #expect(crop.isGeometryOnlyBuiltIn)
        crop.geometry.straighten = 2
        #expect(!crop.isGeometryOnlyBuiltIn)
        #expect(!crop.isIdentity)
    }
}

@Suite("Develop: render engine")
struct RenderEngineTests {
    let engine = RenderEngine.shared

    /// Mid-grey test card with a coloured patch.
    func card(width: CGFloat = 400, height: CGFloat = 300) -> CIImage {
        let grey = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let patch = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: width / 4, height: height / 4))
        return patch.composited(over: grey)
    }

    func average(_ image: CIImage, _ rect: CGRect? = nil) -> SIMD3<Float> {
        let area = rect ?? image.extent
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: area)])
        var px = [Float](repeating: 0, count: 4)
        engine.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                              colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        return SIMD3(px[0], px[1], px[2])
    }

    @Test func exposureAndWhiteBalanceDirection() {
        let source = card()
        let greyArea = CGRect(x: 200, y: 150, width: 100, height: 100)
        var r = EditRecipe(); r.exposure = 1
        let brighter = average(engine.render(source, recipe: r, isRAW: false), greyArea)
        let base = average(source, greyArea)
        #expect(abs(brighter.y / base.y - 2) < 0.05, "+1 EV doubles linear light")

        var warm = EditRecipe(); warm.temperature = 50
        let w = average(engine.render(source, recipe: warm, isRAW: false), greyArea)
        #expect(w.x > w.z, "Warmer temperature raises red over blue")
        var cool = EditRecipe(); cool.temperature = -50
        let c = average(engine.render(source, recipe: cool, isRAW: false), greyArea)
        #expect(c.z > c.x)
    }

    @Test func geometryAndPreviewScale() {
        let source = card(width: 400, height: 300)
        var g = EditRecipe.Geometry()
        g.quarterTurns = 1
        #expect(engine.applyGeometry(source, g).extent.size == CGSize(width: 300, height: 400))
        g = .init(); g.crop = .init(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(engine.applyGeometry(source, g).extent.size == CGSize(width: 200, height: 150))
        g = .init(); g.straighten = 10
        let straightened = engine.applyGeometry(source, g).extent.size
        #expect(straightened.width < 400 && straightened.height < 300)
        #expect(abs(straightened.width / straightened.height - 4.0 / 3) < 0.02, "Keeps aspect")
        var r = EditRecipe(); r.clarity = 30; r.sharpenAmount = 40; r.vignetteAmount = -30; r.grainAmount = 20
        let preview = engine.render(source, recipe: r, isRAW: false, maxPixel: 100)
        #expect(max(preview.extent.width, preview.extent.height) <= 100.5)
        #expect(engine.cgImage(preview) != nil)
    }

    @Test func exportKeepsFormatAndMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "darkroom-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appending(path: "IMG_0001.jpg")
        let cg = engine.cgImage(card())!
        let dest = CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:17 10:30:00"],
                                              kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        var r = EditRecipe(); r.exposure = 0.3; r.geometry.quarterTurns = 1
        let out = dir.appending(path: "IMG_0001-edit.jpg")
        try engine.export(original: original, recipe: r, to: out)
        let props = RenderEngine.metadata(of: out)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 300)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 400)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:17 10:30:00")
        #expect(props[kCGImagePropertyGPSDictionary] != nil)
        #expect(RenderEngine.outputType(for: URL(fileURLWithPath: "/x/IMG.CR3")).ext == "tif")
    }
}

@Suite("Develop: built-in edit mapping")
struct BuiltInMappingTests {
    @Test func cropRoundTripsThroughRotationAndMirroring() {
        let crop = EditRecipe.CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5)
        for turns in 0..<4 {
            for flipH in [false, true] {
                for flipV in [false, true] {
                    let original = VersionManager.cropInOriginalSpace(crop, turns: turns, flipH: flipH, flipV: flipV)
                    let back = VersionManager.cropInDisplaySpace(original, turns: turns, flipH: flipH, flipV: flipV)
                    #expect(abs(back.x - crop.x) < 1e-9 && abs(back.y - crop.y) < 1e-9)
                    #expect(abs(back.width - crop.width) < 1e-9 && abs(back.height - crop.height) < 1e-9)
                }
            }
        }
        // One clockwise turn: the top strip of the rotated image is the left strip of the original.
        let top = VersionManager.cropInOriginalSpace(.init(x: 0, y: 0, width: 1, height: 0.25), turns: 1, flipH: false, flipV: false)
        #expect(top == .init(x: 0, y: 0, width: 0.25, height: 1))
    }
}
