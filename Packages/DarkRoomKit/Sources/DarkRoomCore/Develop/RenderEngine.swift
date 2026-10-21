import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Metal

/// Renders an `EditRecipe` onto an original file with Core Image on the GPU.
///
/// Order (Lightroom-like): RAW decode (white balance, exposure, noise, lens) → geometry → preview scale →
/// white balance (non-RAW) → exposure → highlights/shadows → presence (texture, clarity, dehaze) → global colour
/// LUT (profile, tone, curves, HSL, B&W, grading, vibrance, saturation) → detail (noise, sharpening) → effects.
public final class RenderEngine: @unchecked Sendable {
    public static let shared = RenderEngine()

    public let context: CIContext
    private let lock = NSLock()
    private var lutCache: [Int: Data] = [:]
    private var neutralCache: [String: SIMD3<Float>] = [:]
    private var visionStore: [String: CIImage] = [:]
    /// Per-RAW-file tone/colour curves matching the library's rendition (see `matchLibraryLook`), by file path.
    private var baselines: [String: Data] = [:]

    func visionCache(_ key: String) -> CIImage? { lock.withLock { visionStore[key] } }
    func storeVision(_ image: CIImage, _ key: String) {
        lock.withLock {
            if visionStore.count > 32 { visionStore.removeAll() }
            visionStore[key] = image
        }
    }

    public init() {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: true,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    // MARK: Sources

    /// RAW extensions handled by Apple's RAW engine (anything `CIRAWFilter` supports is tried).
    public static let rawExtensions: Set<String> = ["cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
                                                    "pef", "dng", "srw", "3fr", "fff", "iiq", "mos", "erf", "mef", "mrw", "x3f", "rwl"]

    public static func isRAW(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }

    /// Base image before Develop adjustments. RAW settings that belong to the RAW engine are applied here.
    public func base(_ url: URL, recipe: EditRecipe, draft: Bool = false, scaleFactor: Double = 1) throws -> CIImage {
        if Self.isRAW(url), let raw = CIRAWFilter(imageURL: url) {
            raw.isDraftModeEnabled = draft
            raw.scaleFactor = Float(min(1, max(0.05, scaleFactor)))
            raw.exposure = Float(recipe.exposure)
            raw.boostAmount = Float(recipe.raw.boost)
            raw.boostShadowAmount = Float(recipe.raw.boostShadows)
            raw.localToneMapAmount = Float(recipe.raw.localToneMapping)
            raw.shadowBias = Float(recipe.raw.shadowBias)
            raw.extendedDynamicRangeAmount = Float(recipe.raw.extendedDynamicRange)
            raw.moireReductionAmount = Float(recipe.raw.moireReduction)
            raw.isLensCorrectionEnabled = recipe.raw.lensCorrection
            raw.luminanceNoiseReductionAmount = Float(recipe.noiseLuminance / 100)
            raw.colorNoiseReductionAmount = Float(max(recipe.noiseColor, 0) / 100)
            // Relative shifts (-100…100) work from the camera's as-shot white balance.
            let relative = recipe.temperature != 0 && abs(recipe.temperature) <= 100
            if relative || (recipe.tint != 0 && [.asShot, .custom].contains(recipe.whiteBalance) && recipe.temperature == 0) {
                raw.neutralTemperature = raw.neutralTemperature * Float(1 + recipe.temperature / 100 * 0.6)
                raw.neutralTint = raw.neutralTint + Float(recipe.tint)
            }
            switch recipe.whiteBalance {
            case .asShot: break
            case .custom:
                if let point = recipe.neutralPoint, let size = raw.outputImage?.extent.size {
                    raw.neutralLocation = CGPoint(x: point[0] * size.width, y: (1 - point[1]) * size.height)
                } else if recipe.temperature >= 1000 {
                    raw.neutralTemperature = Float(recipe.temperature)
                    raw.neutralTint = Float(recipe.tint)
                }
            default:
                if let preset = recipe.whiteBalance.preset {
                    raw.neutralTemperature = Float(preset.kelvin)
                    raw.neutralTint = Float(preset.tint)
                }
            }
            guard let image = raw.outputImage else { throw RenderError.unreadable }
            // Same starting look as the library (HDR keeps Apple's decode, whose highlights the curves would clip).
            if !recipe.hdr, let curves = lock.withLock({ baselines[url.path] }) {
                let filter = CIFilter.colorCurves()
                filter.inputImage = image
                filter.curvesData = curves
                filter.curvesDomain = CIVector(x: 0, y: 1)
                filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                return filter.outputImage ?? image
            }
            return image
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]) else {
            throw RenderError.unreadable
        }
        return image
    }

    /// Makes an unedited RAW start out looking like the library's rendition of it (`reference`, e.g. Immich's
    /// preview) instead of Apple's own RAW rendering: per-channel curves found by matching the two images'
    /// histograms, applied straight after the RAW decode for this file from now on (editor and saved versions).
    public func matchLibraryLook(_ url: URL, reference: CGImage) {
        guard Self.isRAW(url), lock.withLock({ baselines[url.path] }) == nil,
              let raw = CIRAWFilter(imageURL: url) else { return }
        raw.scaleFactor = 0.25
        guard let decoded = raw.outputImage else { return }
        let side: CGFloat = 512
        let scaled = decoded.transformed(by: CGAffineTransform(scaleX: side / max(decoded.extent.width, decoded.extent.height),
                                                               y: side / max(decoded.extent.width, decoded.extent.height)))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ours = context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: srgb),
              let mine = Self.histograms(ours), let theirs = Self.histograms(reference) else { return }
        var curves = [Float](repeating: 0, count: 256 * 3)
        for channel in 0..<3 {
            let source = Self.cumulative(mine[channel]), target = Self.cumulative(theirs[channel])
            var j = 0
            for i in 0..<256 {
                while j < 255 && target[j] < source[i] { j += 1 }
                curves[i * 3 + channel] = Float(j) / 255
            }
        }
        // Monotone and smooth: a light running average keeps 8-bit steps from showing as banding.
        var smoothed = curves
        for i in 0..<256 {
            for channel in 0..<3 {
                let lo = max(0, i - 2), hi = min(255, i + 2)
                smoothed[i * 3 + channel] = (lo...hi).map { curves[$0 * 3 + channel] }.reduce(0, +) / Float(hi - lo + 1)
            }
        }
        // Already alike (e.g. the server shows the camera's embedded JPEG): leave Apple's rendering untouched.
        var shift = 0.0, weight = 0.0
        for channel in 0..<3 {
            for i in 0..<256 {
                shift += mine[channel][i] * Double(abs(smoothed[i * 3 + channel] - Float(i) / 255))
                weight += mine[channel][i]
            }
        }
        guard weight > 0, shift / weight > 4.0 / 255 else { return }
        let data = smoothed.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock { baselines[url.path] = data }
    }

    /// 256-bin R, G, B histograms of an image drawn into sRGB.
    private static func histograms(_ image: CGImage) -> [[Double]]? {
        let width = min(image.width, 512), height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        bitmap.interpolationQuality = .medium
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bins = [[Double]](repeating: [Double](repeating: 0, count: 256), count: 3)
        for p in stride(from: 0, to: pixels.count, by: 4) {
            bins[0][Int(pixels[p])] += 1; bins[1][Int(pixels[p + 1])] += 1; bins[2][Int(pixels[p + 2])] += 1
        }
        return bins
    }

    private static func cumulative(_ bins: [Double]) -> [Double] {
        let total = max(1, bins.reduce(0, +))
        var sum = 0.0
        return bins.map { sum += $0; return sum / total }
    }

    /// As-shot neutral temperature/tint of a RAW file (for the White Balance sliders).
    public func rawNeutral(_ url: URL) -> (kelvin: Double, tint: Double)? {
        guard Self.isRAW(url), let raw = CIRAWFilter(imageURL: url) else { return nil }
        return (Double(raw.neutralTemperature), Double(raw.neutralTint))
    }

    // MARK: Pipeline

    /// Applies the recipe. `maxPixel` limits the long edge (previews); radii scale so the look matches export.
    public func render(_ source: CIImage, recipe: EditRecipe, isRAW: Bool, maxPixel: CGFloat? = nil,
                       neutralKey: String? = nil) -> CIImage {
        let g = recipe.geometry
        // Retouch spots and masks live in the rotated/mirrored (uncropped) space.
        let oriented = applyRetouch(orient(source, g), spots: recipe.retouch)
        let lens = recipe.lens
        var image = frame(oriented, g, lens: lens)
        var scale: CGFloat = 1
        if let maxPixel, max(image.extent.width, image.extent.height) > maxPixel {
            scale = maxPixel / max(image.extent.width, image.extent.height)
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(scale)
            filter.aspectRatio = 1
            image = filter.outputImage ?? image
        }
        let extent = image.extent
        let r = recipe
        let frameScale = scale
        let frameAndScale: (CIImage) -> CIImage = { [unowned self] mask in
            let framed = self.frame(mask, g, lens: lens)
            return frameScale < 1 ? framed.transformed(by: CGAffineTransform(scaleX: frameScale, y: frameScale)) : framed
        }
        if r.redEye { image = applyRedEye(image) }

        // White balance for non-RAW (RAW handled by the RAW engine).
        if !isRAW { image = whiteBalance(image, recipe: r, neutralKey: neutralKey) }

        // Exposure (RAW exposure is applied in the RAW engine).
        if !isRAW, r.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: r.exposure])
        }

        if lens.vignetting != 0 { image = correctVignetting(image, lens) }

        // LUT profile (imported .cube or built-in camera look), applied before tone like a camera profile.
        if let id = r.lutProfile, r.lutAmount > 0, let lut = LUTLibrary.shared.lut(id) {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(lut.size)
            filter.cubeData = lut.data
            filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            if let looked = filter.outputImage {
                image = r.lutAmount >= 100 ? looked : dissolve(from: image, to: looked, amount: r.lutAmount / 100)
            }
        }

        // Highlights (negative recovers) and shadows (positive lifts).
        if r.highlights < 0 || r.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(1 + min(0, r.highlights) / 100)
            filter.shadowAmount = Float(r.shadows / 100)
            filter.radius = Float(max(1, 30 * scale))
            image = filter.outputImage ?? image
        }
        if r.highlights > 0 {
            // Brighten highlights: lift the upper part of the tone range.
            let k = r.highlights / 100 * 0.35
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + k * 0.15), "inputPoint3": CIVector(x: 0.75, y: min(1, 0.75 + k * 0.5)),
                "inputPoint4": CIVector(x: 1, y: 1)])
        }

        // Presence: texture (fine), clarity (mid), dehaze (large, with contrast/saturation).
        image = localContrast(image, amount: r.texture / 100 * 0.6, radius: 4 * scale)
        image = localContrast(image, amount: r.clarity / 100 * 0.8, radius: 40 * scale)
        if r.dehaze != 0 {
            image = localContrast(image, amount: r.dehaze / 100 * 0.9, radius: 120 * scale)
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + r.dehaze / 100 * 0.25,
                kCIInputContrastKey: 1 + r.dehaze / 100 * 0.12,
                kCIInputBrightnessKey: -r.dehaze / 100 * 0.04])
        }

        // Global colour via LUT. In HDR mode the LUT works on the SDR-scaled colour and the headroom is
        // restored afterwards, so highlights above SDR white survive.
        let transform = ColorTransform(r)
        if !transform.isIdentity {
            let size = 33
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.cubeDimension = Float(size)
            filter.cubeData = cachedCube(transform, size: size)
            filter.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
            if r.hdr {
                let headroom = image.applyingFilter("CIMaximumComponent")
                    .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                                                                 "inputMaxComponents": CIVector(x: 64, y: 64, z: 64, w: 1)])
                filter.inputImage = headroom.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: image])
                if let graded = filter.outputImage {
                    image = graded.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: headroom]).cropped(to: extent)
                }
            } else {
                filter.inputImage = image
                image = filter.outputImage ?? image
            }
        }
        if lens.purpleFringe > 0 || lens.greenFringe > 0 { image = defringe(image, lens, scale: scale) }

        // Local adjustments through masks.
        if r.hasMasks {
            image = applyMasks(image, recipe: r, oriented: oriented, scale: scale, sourceKey: neutralKey, frameAndScale: frameAndScale)
        }

        // Detail (non-RAW noise reduction; RAW noise is in the RAW engine).
        if !isRAW, r.noiseLuminance > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(r.noiseLuminance / 100 * 0.06)
            filter.sharpness = 0.4
            image = filter.outputImage ?? image
        }
        if !isRAW, r.noiseColor > 0 {
            // Chroma smoothing: blurred colour, original luminance.
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: Double(max(1, r.noiseColor / 100 * 8 * scale))).cropped(to: extent)
            let colorOnly = blurred.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            image = dissolve(from: image, to: colorOnly, amount: min(1, r.noiseColor / 60))
        }
        if r.sharpenAmount > 0 {
            let sharpened = image.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(0.3, r.sharpenRadius * Double(scale) * 1.2),
                kCIInputIntensityKey: r.sharpenAmount / 100 * (0.6 + r.sharpenDetail / 100 * 0.8)])
            if r.sharpenMasking > 0 {
                // Sharpen edges only: edge strength mask thresholded by Masking.
                let edges = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4])
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                    .applyingFilter("CIColorClamp")
                    .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -r.sharpenMasking / 100 * 3])
                    .applyingGaussianBlur(sigma: 1).cropped(to: extent)
                image = sharpened.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: edges])
            } else {
                image = sharpened
            }
        }

        // Effects.
        if r.vignetteAmount != 0 { image = vignette(image, recipe: r) }
        if r.grainAmount > 0 { image = grain(image, recipe: r, scale: scale) }

        return image.cropped(to: extent)
    }

    /// Rotation, mirroring, straighten (auto-cropped to the largest upright rectangle) and crop.
    public func applyGeometry(_ input: CIImage, _ g: EditRecipe.Geometry) -> CIImage {
        frame(orient(input, g), g)
    }

    /// Largest axis-aligned rectangle with the image's aspect inside the image rotated by `angle`.
    public static func inscribedSize(_ size: CGSize, angle: Double) -> CGSize {
        let a = abs(angle), w = size.width, h = size.height
        guard a > 1e-6 else { return size }
        let sinA = sin(a), cosA = cos(a)
        // Scale factor so a w×h box rotated by `a` fits inside the w×h canvas.
        let scale = min(w / (w * cosA + h * sinA), h / (w * sinA + h * cosA))
        return CGSize(width: floor(w * scale), height: floor(h * scale))
    }

    private func localContrast(_ image: CIImage, amount: Double, radius: CGFloat) -> CIImage {
        guard amount != 0 else { return image }
        if amount > 0 {
            return image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(1, radius), kCIInputIntensityKey: amount])
        }
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: Double(max(1, radius / 2))).cropped(to: image.extent)
        return dissolve(from: image, to: blurred, amount: min(1, -amount))
    }

    private func dissolve(from: CIImage, to: CIImage, amount: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = from
        filter.targetImage = to
        filter.time = Float(max(0, min(1, amount)))
        return filter.outputImage ?? from
    }

    private func whiteBalance(_ image: CIImage, recipe: EditRecipe, neutralKey: String?) -> CIImage {
        var out = image
        if recipe.whiteBalance == .custom, let point = recipe.neutralPoint, let key = neutralKey {
            // Eyedropper: per-channel gains that make the sampled area neutral.
            let sample = neutralSample(image, point: point, key: key)
            let mean = (sample.x + sample.y + sample.z) / 3
            if sample.x > 0.001, sample.y > 0.001, sample.z > 0.001 {
                out = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(mean / sample.x), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(mean / sample.y), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(mean / sample.z), w: 0)])
            }
        }
        var temperature = recipe.temperature, tint = recipe.tint
        if let preset = recipe.whiteBalance.preset {
            // Presets relative to daylight for already-rendered files.
            temperature = (preset.kelvin - 5500) / 40
            tint = preset.tint
        }
        if recipe.whiteBalance == .asShot { temperature = recipe.temperature; tint = recipe.tint }
        if temperature != 0 || tint != 0 {
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - temperature * 40, y: -tint)])
        }
        return out
    }

    private func neutralSample(_ image: CIImage, point: [Double], key: String) -> SIMD3<Float> {
        let cacheKey = "\(key)-\(point)"
        lock.lock(); let cached = neutralCache[cacheKey]; lock.unlock()
        if let cached { return cached }
        let extent = image.extent
        let rect = CGRect(x: extent.minX + point[0] * extent.width - 4, y: extent.minY + (1 - point[1]) * extent.height - 4, width: 9, height: 9)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let value = SIMD3(pixel[0], pixel[1], pixel[2])
        lock.lock(); neutralCache[cacheKey] = value; lock.unlock()
        return value
    }

    private func vignette(_ image: CIImage, recipe r: EditRecipe) -> CIImage {
        let extent = image.extent
        let centre = CIVector(x: extent.midX, y: extent.midY)
        let half = min(extent.width, extent.height) / 2
        let roundness = r.vignetteRoundness / 100            // -100 (oval to frame) … 100 (circle)
        let inner = half * (0.4 + r.vignetteMidpoint / 100 * 0.9)
        let outer = inner + half * (0.05 + r.vignetteFeather / 100 * 1.2)
        var mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": inner, "inputRadius1": outer,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1)])!.outputImage!
        // Stretch to the frame's aspect unless fully round.
        let aspect = extent.width / extent.height
        let sx = roundness >= 1 ? 1 : (aspect > 1 ? 1 + (aspect - 1) * (1 - max(0, roundness)) : 1)
        let sy = roundness >= 1 ? 1 : (aspect < 1 ? 1 + (1 / aspect - 1) * (1 - max(0, roundness)) : 1)
        mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: centre.x, y: centre.y)))
            .cropped(to: extent)
        let strength = abs(r.vignetteAmount) / 100
        let target = r.vignetteAmount < 0
            ? image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2.2 * strength])
            : image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.6 * strength])
        return target.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
    }

    private func grain(_ image: CIImage, recipe r: EditRecipe, scale: CGFloat) -> CIImage {
        let extent = image.extent
        let size = max(0.5, (0.5 + r.grainSize / 100 * 2.5) * scale)
        let noise = CIFilter.randomGenerator().outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .transformed(by: CGAffineTransform(scaleX: size, y: size))
            .applyingGaussianBlur(sigma: Double(size) * (1.1 - r.grainRoughness / 100) * 0.6)
            .cropped(to: extent)
        let amount = r.grainAmount / 100 * 0.35
        let grainLayer = noise.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + amount * 3])
        let blended = grainLayer.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        return dissolve(from: image, to: blended, amount: min(1, amount * 2.5))
    }

    private func cachedCube(_ transform: ColorTransform, size: Int) -> Data {
        var hasher = Hasher()
        hasher.combine(transform.recipe.lutKey)
        hasher.combine(size)
        let key = hasher.finalize()
        lock.lock(); let cached = lutCache[key]; lock.unlock()
        if let cached { return cached }
        let data = transform.cubeData(size: size)
        lock.lock()
        if lutCache.count > 24 { lutCache.removeAll() }
        lutCache[key] = data
        lock.unlock()
        return data
    }

    // MARK: Output

    /// Renders to a CGImage (8-bit sRGB/P3 for previews).
    public func cgImage(_ image: CIImage, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!,
                        format: CIFormat = .RGBA8) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: format, colorSpace: colorSpace)
    }

    /// Output file type for an original, per the plan: same format; RAW → 16-bit ProPhoto TIFF.
    public static func outputType(for original: URL, hdr: Bool = false) -> (type: UTType, ext: String) {
        let ext = original.pathExtension.lowercased()
        // HDR from RAW goes to HEIC with a gain map (TIFF can't carry one).
        if isRAW(original) { return hdr ? (.heic, "heic") : (.tiff, "tif") }
        switch ext {
        case "jpg", "jpeg": return (.jpeg, ext)
        case "heic", "heif": return (.heic, ext)
        case "png": return (.png, "png")
        case "tif", "tiff": return (.tiff, ext)
        default: return (.jpeg, "jpg")
        }
    }

    /// Full-resolution render written next to `destination`, in the original's format, with its metadata.
    public func export(original: URL, recipe: EditRecipe, to destination: URL, extraProperties: [CFString: Any] = [:]) throws {
        let isRAW = Self.isRAW(original)
        let base = try base(original, recipe: recipe)
        let rendered = render(base, recipe: recipe, isRAW: isRAW, neutralKey: original.path)
        let (type, _) = Self.outputType(for: original, hdr: recipe.hdr)
        if recipe.hdr, type == .heic || type == .jpeg {
            try exportHDR(rendered, type: type, original: original, to: destination)
            return
        }
        let sixteenBit = isRAW || type == .tiff || type == .png && Self.bitDepth(original) > 8
        let colorSpace = isRAW ? CGColorSpace(name: CGColorSpace.rommrgb)! : (Self.colorSpace(original) ?? CGColorSpace(name: CGColorSpace.displayP3)!)
        guard let cg = context.createCGImage(rendered, from: rendered.extent, format: sixteenBit ? .RGBA16 : .RGBA8, colorSpace: colorSpace)
        else { throw RenderError.renderFailed }

        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw RenderError.writeFailed
        }
        var properties = Self.metadata(of: original)
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = cg.width
        properties[kCGImagePropertyPixelHeight] = cg.height
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cg.width
            exif[kCGImagePropertyExifPixelYDimension] = cg.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            tiff[kCGImagePropertyTIFFSoftware] = "DarkRoom"
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        switch type {
        case .jpeg, .heic: properties[kCGImageDestinationLossyCompressionQuality] = Self.estimatedQuality(original)
        case .tiff: properties[kCGImagePropertyTIFFDictionary] = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:])
            .merging([kCGImagePropertyTIFFCompression: 8], uniquingKeysWith: { $1 })   // Deflate/ZIP
        default: break
        }
        for (k, v) in extraProperties { properties[k] = v }
        properties.removeValue(forKey: kCGImagePropertyDNGDictionary)
        properties.removeValue(forKey: kCGImagePropertyMakerAppleDictionary)
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.writeFailed }
    }

    /// Writes an external editor's result in the original's format (RAW → 16-bit ProPhoto TIFF), with the
    /// original's metadata (the editor's pixels are already upright, so orientation is reset).
    public func transcode(_ result: URL, like original: URL, to destination: URL) throws {
        guard let image = CIImage(contentsOf: result, options: [.applyOrientationProperty: true]) else { throw RenderError.unreadable }
        let (type, _) = Self.outputType(for: original)
        let sixteen = Self.isRAW(original) || type == .tiff || (type == .png && Self.bitDepth(original) > 8) || Self.bitDepth(result) > 8 && type == .tiff
        let colorSpace = Self.isRAW(original) ? CGColorSpace(name: CGColorSpace.rommrgb)! : (image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!)
        guard let cg = context.createCGImage(image, from: image.extent, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: colorSpace),
              let dest = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else { throw RenderError.writeFailed }
        var properties = Self.metadata(of: original)
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = cg.width
        properties[kCGImagePropertyPixelHeight] = cg.height
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            if type == .tiff { tiff[kCGImagePropertyTIFFCompression] = 8 }
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if type == .jpeg || type == .heic { properties[kCGImageDestinationLossyCompressionQuality] = Self.estimatedQuality(original) }
        properties.removeValue(forKey: kCGImagePropertyDNGDictionary)
        properties.removeValue(forKey: kCGImagePropertyMakerAppleDictionary)
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.writeFailed }
    }

    /// ExifTool used to copy metadata into files Core Image writes itself (set by the app).
    public nonisolated(unsafe) static var exiftoolURL: URL?

    /// HDR HEIC/JPEG: an SDR rendition plus an ISO gain map from the HDR image; metadata copied from the original.
    func exportHDR(_ hdr: CIImage, type: UTType, original: URL, to destination: URL) throws {
        let sdr = hdr.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0])
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Self.estimatedQuality(original),
        ]
        let data = type == .heic
            ? context.heifRepresentation(of: sdr, format: .RGBA8, colorSpace: colorSpace, options: options)
            : context.jpegRepresentation(of: sdr, colorSpace: colorSpace, options: options)
        guard let data else { throw RenderError.writeFailed }
        try data.write(to: destination, options: .atomic)
        // Core Image writes no camera metadata: copy it from the original (lossless).
        if let exiftool = Self.exiftoolURL {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [exiftool.path, "-overwrite_original", "-P", "-m", "-TagsFromFile", original.path,
                                 "-all:all", "-Orientation=1", "-n", "-Software=DarkRoom", destination.path]
            process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
    }

    static func metadata(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        return props
    }

    static func bitDepth(_ url: URL) -> Int { metadata(of: url)[kCGImagePropertyDepth] as? Int ?? 8 }

    static func colorSpace(_ url: URL) -> CGColorSpace? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.colorSpace
    }

    /// Quality estimate from bits per pixel (ImageIO doesn't expose quantisation tables).
    static func estimatedQuality(_ url: URL) -> Double {
        let props = metadata(of: url)
        guard let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, w > 0, h > 0 else { return 0.92 }
        let bpp = Double(bytes * 8) / Double(w * h)
        let isHEIC = ["heic", "heif"].contains(url.pathExtension.lowercased())
        let thresholds: [(Double, Double)] = isHEIC ? [(2.2, 0.95), (1.4, 0.9), (0.8, 0.85)] : [(4.5, 0.96), (3.0, 0.92), (1.8, 0.88)]
        return thresholds.first { bpp >= $0.0 }?.1 ?? 0.82
    }

    public enum RenderError: Error { case unreadable, renderFailed, writeFailed }
}

extension EditRecipe {
    /// The part of the recipe that affects the global colour LUT.
    var lutKey: Int {
        var copy = EditRecipe()
        copy.profile = profile; copy.profileAmount = profileAmount; copy.contrast = contrast; copy.whites = whites
        copy.blacks = blacks; copy.parametric = parametric; copy.curveRGB = curveRGB; copy.curveRed = curveRed
        copy.curveGreen = curveGreen; copy.curveBlue = curveBlue; copy.hsl = hsl; copy.monochrome = monochrome
        copy.bwMix = bwMix; copy.grading = grading; copy.vibrance = vibrance; copy.saturation = saturation
        return copy.hashValue
    }
}
