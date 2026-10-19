import Foundation
import Testing
import CoreImage
import simd
@testable import DarkRoomCore

@Suite("Develop: masks, local adjustments and retouch")
struct MaskTests {
    let engine = RenderEngine.shared

    func grey(_ w: CGFloat = 400, _ h: CGFloat = 300, _ v: CGFloat = 0.25) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    func average(_ image: CIImage, _ rect: CGRect) -> Float {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        engine.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                              colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        return px[1]
    }

    /// The unedited grey, measured the same way (linear light).
    var base: Float { average(grey(), CGRect(x: 10, y: 10, width: 50, height: 50)) }

    // Core Image y is bottom-up: "top" of the photo is high y.
    let top = CGRect(x: 150, y: 250, width: 100, height: 40)
    let bottom = CGRect(x: 150, y: 10, width: 100, height: 40)

    @Test func linearGradientOnlyAffectsItsSide() {
        var r = EditRecipe()
        r.masks = [Mask(name: "Sky", components: [MaskComponent(.linear(start: [0.5, 0], end: [0.5, 0.5]))])]
        r.masks[0].adjust.exposure = 1
        let out = engine.render(grey(), recipe: r, isRAW: false)
        #expect(average(out, top) > average(grey(), top) * 1.6, "Top brightened")
        #expect(abs(average(out, bottom) - average(grey(), bottom)) < 0.005, "Bottom untouched")
    }

    @Test func radialInsideAndInverted() {
        var r = EditRecipe()
        r.masks = [Mask(name: "Spot", components: [MaskComponent(.radial(center: [0.5, 0.5], radius: [0.15, 0.2], angle: 0, feather: 10, inside: true))])]
        r.masks[0].adjust.exposure = 1
        let centre = CGRect(x: 190, y: 140, width: 20, height: 20), corner = CGRect(x: 5, y: 5, width: 20, height: 20)
        var out = engine.render(grey(), recipe: r, isRAW: false)
        #expect(average(out, centre) > base * 1.8)
        #expect(abs(average(out, corner) - base) < base * 0.05)
        r.masks[0].inverted = true
        out = engine.render(grey(), recipe: r, isRAW: false)
        #expect(abs(average(out, centre) - base) < base * 0.05)
        #expect(average(out, corner) > base * 1.8)
    }

    @Test func brushAndLuminanceRange() {
        var r = EditRecipe()
        let stroke = BrushStroke(points: [[0.1, 0.5], [0.4, 0.5]], size: 0.1, feather: 0)
        r.masks = [Mask(name: "Brush", components: [MaskComponent(.brush(strokes: [stroke]))])]
        r.masks[0].adjust.exposure = -1
        let out = engine.render(grey(), recipe: r, isRAW: false)
        #expect(average(out, CGRect(x: 80, y: 145, width: 30, height: 10)) < base * 0.6, "Painted area darkened")
        #expect(abs(average(out, CGRect(x: 300, y: 145, width: 30, height: 10)) - base) < base * 0.03, "Unpainted area untouched")

        // Bright patch selected by luminance range.
        let patch = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = patch.composited(over: grey())
        var lum = EditRecipe()
        lum.masks = [Mask(name: "Highlights", components: [MaskComponent(.luminanceRange(low: 0.7, high: 1, smoothness: 10))])]
        lum.masks[0].adjust.exposure = -1
        let lumOut = engine.render(image, recipe: lum, isRAW: false)
        let brightBefore = average(image, CGRect(x: 30, y: 30, width: 40, height: 40))
        #expect(average(lumOut, CGRect(x: 30, y: 30, width: 40, height: 40)) < brightBefore * 0.7, "Bright area adjusted")
        #expect(abs(average(lumOut, CGRect(x: 250, y: 200, width: 40, height: 40)) - base) < base * 0.05, "Dark area untouched")
    }

    @Test func masksFollowTheCrop() {
        // Mask on the right half of the uncropped photo; crop keeps only the right half.
        var r = EditRecipe()
        r.masks = [Mask(name: "Right", components: [MaskComponent(.linear(start: [1, 0.5], end: [0.75, 0.5]))])]
        r.masks[0].adjust.exposure = 1
        r.geometry.crop = .init(x: 0.5, y: 0, width: 0.5, height: 1)
        let out = engine.render(grey(), recipe: r, isRAW: false)
        #expect(out.extent.width == 200)
        #expect(average(out, CGRect(x: 180, y: 140, width: 15, height: 20)) > base * 1.6, "Right edge of the crop is brightened")
        #expect(abs(average(out, CGRect(x: 5, y: 140, width: 15, height: 20)) - base) < base * 0.05, "Left edge of the crop (photo centre) untouched")
    }

    @Test func healRemovesABlemish() {
        let blemish = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 195, y: 145, width: 10, height: 10))
        let image = blemish.composited(over: grey())
        let spot = CGRect(x: 197, y: 147, width: 6, height: 6)
        #expect(average(image, spot) < base * 0.1)
        var r = EditRecipe()
        r.retouch = [RetouchSpot(mode: .heal, center: [0.5, 0.5], radius: 0.03, source: [0.25, 0.5])]
        #expect(abs(average(engine.render(image, recipe: r, isRAW: false), spot) - base) < base * 0.15, "Healed to the surrounding grey")
        r.retouch = [RetouchSpot(mode: .remove, center: [0.5, 0.5], radius: 0.03)]
        #expect(abs(average(engine.render(image, recipe: r, isRAW: false), spot) - base) < base * 0.15, "Content-aware remove")
    }
}
