import Foundation
import Testing
import CoreImage
@testable import DarkRoomCore

@Suite("Develop: HDR merge and panorama")
struct MergeTests {
    let engine = RenderEngine.shared

    /// A detailed scene (noise + checker + gradient) so Vision finds features.
    func scene(width: CGFloat = 1800, height: CGFloat = 600, brightness: CGFloat = 1) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // CIRandomGenerator tiles every 512 px; scaled 4× it doesn't repeat inside the scene.
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4)).cropped(to: rect)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.3])
            .applyingGaussianBlur(sigma: 1).cropped(to: rect)
        // Non-repeating structure (a periodic pattern would let alignment lock onto the wrong period).
        let horizontal = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: width, y: 0),
            "inputColor0": CIColor(red: 0.2, green: 0.35, blue: 0.6), "inputColor1": CIColor(red: 0.85, green: 0.6, blue: 0.35)])!.outputImage!
        let blobs = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: width * 0.37, y: height * 0.6), "inputRadius0": 40,
            "inputRadius1": 260, "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0.5, green: 0.5, blue: 0.5)])!.outputImage!
        let checker = blobs.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: horizontal]).cropped(to: rect)
        return noise.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: checker])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(brightness)])
            .cropped(to: rect)
    }

    func rendered(_ image: CIImage) -> CIImage {
        CIImage(cgImage: engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!)
    }

    @Test func panoramaStitchesOverlappingFrames() throws {
        let full = rendered(scene())
        let frames = [0, 500, 1000].map { x -> CIImage in
            full.cropped(to: CGRect(x: CGFloat(x), y: 0, width: 800, height: 600))
                .transformed(by: CGAffineTransform(translationX: -CGFloat(x), y: 0))
        }
        let pano = try #require(Merge.panorama(frames))
        #expect(pano.extent.width > 1500, "Wider than any frame (\(pano.extent.width))")
        #expect(pano.extent.height > 500)
        #expect(engine.cgImage(pano) != nil)
        // Unrelated photos are refused instead of being blended into a mess.
        let other = rendered(CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 6, y: 6)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
            .applyingGaussianBlur(sigma: 2).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600)))
        #expect(Merge.panorama([frames[0], other]) == nil)
        // Cylindrical projection: width compresses (f·atan), centre column keeps full height, corners pull in.
        let cyl = Merge.cylindrical(frames[0], focal: 880)
        let expectedWidth = 2 * 880 * atan(400.0 / 880)
        #expect(abs(cyl.extent.width - expectedWidth) < 4, "Projected width \(cyl.extent.width) ≈ \(expectedWidth)")
        #expect(abs(cyl.extent.height - 600) < 2)
    }

    @Test func hdrRecoversHighlightsAndAligns() throws {
        // Radiance with a bright region at 3×.
        let base = rendered(scene(width: 800, height: 600))
        let hot = base.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.6]).cropped(to: CGRect(x: 300, y: 200, width: 200, height: 200))
        let radiance = hot.composited(over: base)
        func exposure(_ ev: Double, shift: CGFloat) -> Merge.Source {
            let img = radiance.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
                .applyingFilter("CIColorClamp")
                .transformed(by: CGAffineTransform(translationX: shift, y: shift / 2))
                .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
            return Merge.Source(image: rendered(img), exposure: pow(2, ev))
        }
        let merged = try #require(Merge.hdr([exposure(-2, shift: 4), exposure(0, shift: 0), exposure(2, shift: -3)]))
        let region = CGRect(x: 350, y: 250, width: 100, height: 100)
        func avg(_ i: CIImage) -> Float {
            let a = i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
            var px = [Float](repeating: 0, count: 4)
            engine.context.render(a, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                                  colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
            return max(px[0], px[1], px[2])
        }
        #expect(avg(merged) > 1.0, "Highlight detail beyond the normal exposure's clipping (\(avg(merged)))")
        #expect(merged.extent.size == CGSize(width: 800, height: 600))
    }
}
