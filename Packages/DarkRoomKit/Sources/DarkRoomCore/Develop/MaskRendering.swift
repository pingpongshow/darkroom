import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Vision
import simd

/// Masks, local adjustments, retouching and red-eye for `RenderEngine`.
extension RenderEngine {

    // MARK: Geometry split (masks share the photo's straighten / crop / scale)

    /// 90° rotation and mirroring only (the space masks and retouch spots are defined in).
    public func orient(_ input: CIImage, _ g: EditRecipe.Geometry) -> CIImage {
        var image = input
        switch ((g.quarterTurns % 4) + 4) % 4 {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        if g.flipHorizontal { image = image.oriented(.upMirrored) }
        if g.flipVertical { image = image.oriented(.downMirrored) }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// Straighten (auto-cropped) and crop, applied to an oriented image (or a mask with the same extent).
    public func frame(_ oriented: CIImage, _ g: EditRecipe.Geometry) -> CIImage {
        var image = oriented
        if g.straighten != 0 {
            let size = image.extent.size
            let angle = g.straighten * .pi / 180
            let rotated = image.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                .concatenating(CGAffineTransform(rotationAngle: -angle))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)))
            let inner = Self.inscribedSize(size, angle: angle)
            let rect = CGRect(x: (size.width - inner.width) / 2, y: (size.height - inner.height) / 2, width: inner.width, height: inner.height)
            image = rotated.cropped(to: rect.integral)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if let crop = g.crop, crop != .full {
            let size = image.extent.size
            let rect = CGRect(x: crop.x * size.width, y: (1 - crop.y - crop.height) * size.height,
                              width: crop.width * size.width, height: crop.height * size.height).integral
            image = image.cropped(to: rect)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        return image
    }

    /// Normalised (top-left) point → Core Image coordinates in an oriented extent.
    static func point(_ p: [Double], in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + (p[safe: 0] ?? 0.5) * extent.width, y: extent.minY + (1 - (p[safe: 1] ?? 0.5)) * extent.height)
    }

    // MARK: Masks

    /// A greyscale mask (white = full effect) in oriented space.
    public func maskImage(_ mask: Mask, oriented: CIImage, sourceKey: String?) -> CIImage {
        let extent = oriented.extent
        var result: CIImage?
        for component in mask.components {
            let layer = componentImage(component.kind, oriented: oriented, sourceKey: sourceKey).cropped(to: extent)
            guard let current = result else {
                result = component.operation == .subtract ? invert(layer) : layer
                continue
            }
            switch component.operation {
            case .add: result = layer.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: current])
            case .subtract: result = invert(layer).applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: current])
            case .intersect: result = layer.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: current])
            }
        }
        var out = (result ?? CIImage(color: .black)).cropped(to: extent)
        if mask.inverted { out = invert(out) }
        return out
    }

    private func invert(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorInvert").applyingFilter("CIColorClamp")
    }

    private func componentImage(_ kind: MaskKind, oriented: CIImage, sourceKey: String?) -> CIImage {
        let extent = oriented.extent
        switch kind {
        case .linear(let start, let end):
            let filter = CIFilter.linearGradient()
            filter.point0 = Self.point(start, in: extent)
            filter.point1 = Self.point(end, in: extent)
            filter.color0 = .white
            filter.color1 = .black
            return filter.outputImage!.cropped(to: extent)

        case .radial(let center, let radius, let angle, let feather, let inside):
            let rx = max(1, (radius[safe: 0] ?? 0.25) * extent.width), ry = max(1, (radius[safe: 1] ?? 0.25) * extent.height)
            let outer = rx
            let inner = outer * max(0, 1 - feather / 100)
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": inner, "inputRadius1": outer,
                "inputColor0": inside ? CIColor.white : CIColor.black, "inputColor1": inside ? CIColor.black : CIColor.white])!.outputImage!
            let c = Self.point(center, in: extent)
            let transform = CGAffineTransform(scaleX: 1, y: ry / rx)
                .concatenating(CGAffineTransform(rotationAngle: -angle * .pi / 180))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            return gradient.transformed(by: transform).cropped(to: extent)

        case .brush(let strokes):
            return brushImage(strokes, extent: extent)

        case .subject, .background:
            let subject = visionMask(.subject, oriented: oriented, sourceKey: sourceKey)
            return kind == .background ? invert(subject) : subject

        case .people:
            return visionMask(.people, oriented: oriented, sourceKey: sourceKey)

        case .sky:
            return skyMask(oriented)

        case .colorRange(let hue, let saturation, let range):
            return colorRangeMask(oriented, hue: hue, saturation: saturation, range: range)

        case .luminanceRange(let low, let high, let smoothness):
            return luminanceRangeMask(oriented, low: low, high: high, smoothness: smoothness)

        case .depthRange(let near, let far, let smoothness):
            return depthMask(sourceKey: sourceKey, extent: extent, near: near, far: far, smoothness: smoothness)
        }
    }

    /// Rasterises brush strokes (soft round stamps along each stroke) into a greyscale mask.
    private func brushImage(_ strokes: [BrushStroke], extent: CGRect) -> CIImage {
        let longEdge = max(extent.width, extent.height)
        // Masks don't need full resolution: 2048 px on the long edge, scaled up smoothly.
        let scale = min(1, 2048 / longEdge)
        let w = max(1, Int(extent.width * scale)), h = max(1, Int(extent.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .black).cropped(to: extent)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for stroke in strokes {
            let diameter = max(1, stroke.size * Double(max(w, h)))
            let r = diameter / 2
            let hardness = max(0.01, 1 - stroke.feather / 100)
            let alpha = max(0.02, stroke.flow / 100)
            let colors = [CGColor(gray: stroke.erase ? 0 : 1, alpha: alpha), CGColor(gray: stroke.erase ? 0 : 1, alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [hardness, 1]) else { continue }
            ctx.setBlendMode(stroke.erase ? .destinationOut : .normal)
            let pts = stroke.points.map { CGPoint(x: ($0[safe: 0] ?? 0) * Double(w), y: (1 - ($0[safe: 1] ?? 0)) * Double(h)) }
            var stamps: [CGPoint] = pts.isEmpty ? [] : [pts[0]]
            // Stamp every quarter radius along the path.
            for (a, b) in zip(pts, pts.dropFirst()) {
                let distance = hypot(b.x - a.x, b.y - a.y)
                let steps = max(1, Int(distance / max(1, r / 4)))
                for i in 1...steps { let t = CGFloat(i) / CGFloat(steps); stamps.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
            }
            for c in stamps {
                ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }
        }
        guard let cg = ctx.makeImage() else { return CIImage(color: .black).cropped(to: extent) }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    // MARK: Vision masks (cached per source and orientation)

    enum VisionKind: String { case subject, people }

    func visionMask(_ kind: VisionKind, oriented: CIImage, sourceKey: String?) -> CIImage {
        let extent = oriented.extent
        let key = "\(sourceKey ?? "anon")-\(kind.rawValue)-\(Int(extent.width))x\(Int(extent.height))"
        if let cached = visionCache(key) { return Self.fit(cached, to: extent) }
        // Vision runs on a ~1536 px copy; the mask is scaled to the photo.
        let scale = min(1, 1536 / max(extent.width, extent.height))
        let small = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return CIImage(color: .black).cropped(to: extent) }
        let handler = VNImageRequestHandler(cgImage: cg)
        var maskImage: CIImage?
        switch kind {
        case .subject:
            let request = VNGenerateForegroundInstanceMaskRequest()
            if (try? handler.perform([request])) != nil, let observation = request.results?.first,
               let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
                maskImage = CIImage(cvPixelBuffer: buffer)
            }
        case .people:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            if (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer {
                maskImage = CIImage(cvPixelBuffer: buffer)
            }
        }
        let result = maskImage ?? CIImage(color: .black).cropped(to: small.extent)
        // Render once so later uses don't re-run Vision.
        if let rendered = context.createCGImage(result, from: result.extent) {
            let image = CIImage(cgImage: rendered)
            storeVision(image, key)
            return Self.fit(image, to: extent)
        }
        return Self.fit(result, to: extent)
    }

    static func fit(_ image: CIImage, to extent: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / e.width, y: extent.height / e.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .cropped(to: extent)
    }

    /// Sky: bright, blue or neutral, smooth areas, favouring the top of the frame.
    private func skyMask(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let small = max(extent.width, extent.height) > 1024
            ? image.transformed(by: CGAffineTransform(scaleX: 1024 / max(extent.width, extent.height), y: 1024 / max(extent.width, extent.height)))
            : image
        // Blueness (b - r) plus brightness.
        let blue = small.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -0.6, y: 0.1, z: 1.1, w: 0), "inputGVector": CIVector(x: -0.6, y: 0.1, z: 1.1, w: 0),
            "inputBVector": CIVector(x: -0.6, y: 0.1, z: 1.1, w: 0), "inputBiasVector": CIVector(x: 0.05, y: 0.05, z: 0.05, w: 0)])
        let bright = small.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.5])
        // Smooth regions only (sky has little texture).
        let edges = small.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingGaussianBlur(sigma: 6)
        let vertical = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: small.extent.maxY), "inputPoint1": CIVector(x: 0, y: small.extent.minY + small.extent.height * 0.35),
            "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: small.extent)
        let score = blue.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: bright.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.7])])
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: vertical])
        let smooth = invert(edges.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2.5]).applyingFilter("CIColorClamp"))
        let mask = score.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: smooth])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.2, kCIInputBrightnessKey: 0.1])
            .applyingFilter("CIColorClamp")
            .applyingGaussianBlur(sigma: 4)
            .cropped(to: small.extent)
        return Self.fit(mask, to: extent)
    }

    private func colorRangeMask(_ image: CIImage, hue: Double, saturation: Double, range: Double) -> CIImage {
        // A small LUT: weight by hue distance (and saturation) from the sampled colour.
        let size = 24
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        let width = Float(max(5, range)) / 100 * 60   // degrees
        var i = 0
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let hsl = ColorTransform.rgbToHSL(SIMD3(Float(r), Float(g), Float(b)) / Float(size - 1))
            var w = ColorTransform.bandWeight(hue: hsl.x * 360, centre: Float(hue), width: width * 2)
            w *= min(1, hsl.y / max(0.05, Float(saturation) * 0.5))  // ignore greys
            cube[i] = w; cube[i + 1] = w; cube[i + 2] = w; cube[i + 3] = 1
            i += 4
        } } }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(size)
        filter.cubeData = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return (filter.outputImage ?? image).applyingGaussianBlur(sigma: 2).cropped(to: image.extent)
    }

    /// Perceptual (gamma-encoded) luminance between `low` and `high` with soft edges, via a small LUT.
    private func luminanceRangeMask(_ image: CIImage, low: Double, high: Double, smoothness: Double) -> CIImage {
        let soft = Float(max(0.01, smoothness / 100 * 0.25))
        let lo = Float(low), hi = Float(high)
        func weight(_ l: Float) -> Float {
            let rise: Float = lo <= 0 ? 1 : simd_smoothstep(lo - soft, lo, l)
            let fall: Float = hi >= 1 ? 1 : 1 - simd_smoothstep(hi, hi + soft, l)
            return rise * fall
        }
        let size = 32
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        var i = 0
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let c = SIMD3(Float(r), Float(g), Float(b)) / Float(size - 1)
            let w = weight(simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)))
            cube[i] = w; cube[i + 1] = w; cube[i + 2] = w; cube[i + 3] = 1
            i += 4
        } } }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(size)
        filter.cubeData = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    private func depthMask(sourceKey: String?, extent: CGRect, near: Double, far: Double, smoothness: Double) -> CIImage {
        guard let path = sourceKey,
              let disparity = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.auxiliaryDisparity: true, .applyOrientationProperty: true])
        else { return CIImage(color: .black).cropped(to: extent) }
        // Disparity is high when near: convert to 0 = near … 1 = far.
        let depth = invert(disparity.applyingFilter("CIColorClamp"))
        return luminanceRangeMask(Self.fit(depth, to: extent), low: near, high: far, smoothness: smoothness)
    }

    // MARK: Local adjustments

    /// Applies each mask's adjustments through its mask. `oriented` is the unframed photo (for Vision and
    /// colour/luminance sampling); `frameAndScale` maps oriented-space masks onto the current image.
    func applyMasks(_ image: CIImage, recipe: EditRecipe, oriented: CIImage, scale: CGFloat, sourceKey: String?,
                    frameAndScale: (CIImage) -> CIImage) -> CIImage {
        var out = image
        let extent = image.extent
        for mask in recipe.masks where mask.isEnabled && !mask.components.isEmpty && !mask.adjust.isIdentity {
            let maskImage = frameAndScale(maskImage(mask, oriented: oriented, sourceKey: sourceKey)).cropped(to: extent)
            let adjusted = applyLocal(out, mask.adjust, scale: scale)
            out = adjusted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: maskImage])
                .cropped(to: extent)
        }
        return out
    }

    func applyLocal(_ input: CIImage, _ a: LocalAdjustments, scale: CGFloat) -> CIImage {
        var image = input
        let extent = input.extent
        if a.temperature != 0 || a.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 40, y: -a.tint)])
        }
        if a.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.highlights < 0 || a.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(1 + min(0, a.highlights) / 100)
            filter.shadowAmount = Float(a.shadows / 100)
            filter.radius = Float(max(1, 30 * scale))
            image = filter.outputImage ?? image
        }
        if a.contrast != 0 || a.saturation != 0 || a.highlights > 0 || a.whites != 0 || a.blacks != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + a.contrast / 100 * 0.5, kCIInputSaturationKey: 1 + a.saturation / 100,
                kCIInputBrightnessKey: (a.highlights > 0 ? a.highlights / 100 * 0.05 : 0) + a.whites / 100 * 0.04 + a.blacks / 100 * 0.04])
        }
        if a.hue != 0 { image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 180]) }
        if a.texture != 0 { image = localContrastPublic(image, amount: a.texture / 100 * 0.6, radius: 4 * scale) }
        if a.clarity != 0 { image = localContrastPublic(image, amount: a.clarity / 100 * 0.8, radius: 40 * scale) }
        if a.dehaze != 0 {
            image = localContrastPublic(image, amount: a.dehaze / 100 * 0.9, radius: 120 * scale)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + a.dehaze / 100 * 0.25,
                                                                kCIInputContrastKey: 1 + a.dehaze / 100 * 0.12])
        }
        if a.sharpness > 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(0.5, 1.2 * scale), kCIInputIntensityKey: a.sharpness / 100])
        } else if a.sharpness < 0 || a.noise > 0 {
            let sigma = Double(max(0.5, (abs(min(0, a.sharpness)) / 100 * 3 + a.noise / 100 * 2) * scale))
            image = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        if a.overlayStrength > 0 {
            let tint = ColorTransform.hslToRGB(SIMD3(Float(a.overlayHue / 360), 1, 0.5))
            let color = CIImage(color: CIColor(red: CGFloat(tint.x), green: CGFloat(tint.y), blue: CGFloat(tint.z))).cropped(to: extent)
            let colored = color.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            let filter = CIFilter.dissolveTransition()
            filter.inputImage = image; filter.targetImage = colored; filter.time = Float(min(1, a.overlayStrength / 100))
            image = filter.outputImage ?? image
        }
        return image.cropped(to: extent)
    }

    func localContrastPublic(_ image: CIImage, amount: Double, radius: CGFloat) -> CIImage {
        guard amount != 0 else { return image }
        if amount > 0 { return image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(1, radius), kCIInputIntensityKey: amount]) }
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: Double(max(1, radius / 2))).cropped(to: image.extent)
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = image; filter.targetImage = blurred; filter.time = Float(min(1, -amount))
        return filter.outputImage ?? image
    }

    // MARK: Retouch (heal / clone / remove) and red-eye

    /// Applied in oriented space before framing, so spots stay put when cropping.
    func applyRetouch(_ oriented: CIImage, spots: [RetouchSpot]) -> CIImage {
        guard !spots.isEmpty else { return oriented }
        let extent = oriented.extent
        var image = oriented
        let longEdge = max(extent.width, extent.height)
        for spot in spots {
            let r = max(2, spot.radius * longEdge)
            let dest = Self.point(spot.center, in: extent)
            let src = spot.source.map { Self.point($0, in: extent) } ?? autoSource(image, dest: dest, radius: r)
            let shifted = image.transformed(by: CGAffineTransform(translationX: dest.x - src.x, y: dest.y - src.y))
            var patch = shifted
            if spot.mode != .clone {
                // Heal: source texture (high frequencies) + destination colour/light (low frequencies).
                // Low frequencies by normalised convolution with the spot itself left out, so the colour/light
                // comes from the spot's surroundings (not from the blemish).
                let sigma = Double(r / 2)
                let hole = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: dest.x, y: dest.y), "inputRadius0": r, "inputRadius1": r * 1.05,
                    "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!.cropped(to: extent)
                func membrane(_ img: CIImage) -> CIImage {
                    let weighted = img.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: hole])
                        .clampedToExtent().applyingGaussianBlur(sigma: sigma)
                    let weights = hole.clampedToExtent().applyingGaussianBlur(sigma: sigma)
                    // CIDivideBlendMode computes background ÷ input.
                    return weights.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: weighted])
                }
                let srcLow = membrane(shifted)
                let dstLow = membrane(image)
                // patch = dstLow + shifted − srcLow (additions in the float working space don't clamp).
                let negSrcLow = srcLow.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
                patch = shifted.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: negSrcLow])
                    .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: dstLow])
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                  "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            }
            let feather = max(0.05, spot.feather / 100)
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: dest.x, y: dest.y), "inputRadius0": r * (1 - feather * 0.8), "inputRadius1": r,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: spot.opacity / 100), "inputColor1": CIColor.black])!.outputImage!
            image = patch.cropped(to: extent)
                .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask.cropped(to: extent)])
                .cropped(to: extent)
        }
        return image
    }

    /// Content-aware source: the nearby circle whose surroundings best match the destination's ring.
    private func autoSource(_ image: CIImage, dest: CGPoint, radius r: CGFloat) -> CGPoint {
        let extent = image.extent
        let ring = sample(image, CGRect(x: dest.x - r * 2, y: dest.y - r * 2, width: r * 4, height: r * 4))
        var best = CGPoint(x: dest.x + r * 2.5, y: dest.y)
        var bestScore = Float.greatestFiniteMagnitude
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 6) {
            for distance in [2.5, 3.5, 5.0] {
                let c = CGPoint(x: dest.x + CGFloat(cos(angle)) * r * CGFloat(distance), y: dest.y + CGFloat(sin(angle)) * r * CGFloat(distance))
                guard extent.insetBy(dx: r, dy: r).contains(c) else { continue }
                let candidate = sample(image, CGRect(x: c.x - r * 2, y: c.y - r * 2, width: r * 4, height: r * 4))
                let score = simd_length_squared(candidate - ring) + Float(distance) * 0.0005
                if score < bestScore { bestScore = score; best = c }
            }
        }
        return best
    }

    private func sample(_ image: CIImage, _ rect: CGRect) -> SIMD3<Float> {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect.intersection(image.extent))])
        var px = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        return SIMD3(px[0], px[1], px[2])
    }

    /// Core Image's automatic red-eye correction (faces detected on the photo).
    func applyRedEye(_ image: CIImage) -> CIImage {
        let filters = image.autoAdjustmentFilters(options: [.redEye: true, .enhance: false])
        return filters.reduce(image) { current, filter in
            filter.setValue(current, forKey: kCIInputImageKey)
            return filter.outputImage ?? current
        }
    }
}
