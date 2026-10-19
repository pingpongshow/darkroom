import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import simd

/// HDR merge (bracketed exposures) and panorama stitching, aligned with Apple Vision.
public enum Merge {
    public enum Projection: String, CaseIterable, Sendable { case perspective = "Perspective", cylindrical = "Cylindrical" }

    public struct Source: Sendable {
        public var image: CIImage
        /// Relative exposure (seconds × ISO / f²); nil = unknown.
        public var exposure: Double?
        public init(image: CIImage, exposure: Double?) { self.image = image; self.exposure = exposure }
    }

    /// Reads a file and its exposure from EXIF.
    public static func source(_ url: URL, engine: RenderEngine = .shared) throws -> Source {
        let image = try engine.base(url, recipe: EditRecipe())
        let props = (CGImageSourceCreateWithURL(url as CFURL, nil)).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var exposure: Double?
        if let t = exif?[kCGImagePropertyExifExposureTime] as? Double {
            let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first ?? 100
            let f = exif?[kCGImagePropertyExifFNumber] as? Double ?? 1
            exposure = t * iso / max(0.5, f * f)
        }
        return Source(image: image, exposure: exposure)
    }

    // MARK: Alignment

    /// Homography mapping `floating` onto `reference` (Vision), as a 3×3 matrix in pixel coordinates.
    /// Vision's homographic registration fails on large shifts, so a translational estimate comes first and the
    /// homography only refines it.
    static func homography(_ floating: CIImage, onto reference: CIImage) -> simd_float3x3? {
        let translation = VNTranslationalImageRegistrationRequest(targetedCIImage: floating)
        try? VNImageRequestHandler(ciImage: reference).perform([translation])
        let visionShift = (translation.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform
        // Vision's estimate is checked against a direct search; the better match wins.
        let searched = searchTranslation(floating, onto: reference)
        var t = CGAffineTransform.identity
        if let v = visionShift, let s = searched {
            t = matchError(floating, reference, dx: v.tx, dy: v.ty) <= matchError(floating, reference, dx: s.x, dy: s.y) * 1.02
                ? v : CGAffineTransform(translationX: s.x, y: s.y)
        } else if let v = visionShift {
            t = v
        } else if let s = searched {
            t = CGAffineTransform(translationX: s.x, y: s.y)
        } else {
            return nil
        }
        let coarse = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(Float(t.tx), Float(t.ty), 1)))
        // Refine on the coarsely aligned image (moved back to the origin for Vision, then shifted again).
        let shifted = floating.transformed(by: CGAffineTransform(translationX: t.tx, y: t.ty))
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: shifted.cropped(to: reference.extent))
        try? VNImageRequestHandler(ciImage: reference).perform([request])
        if let refine = (request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform,
           abs(refine.columns.2.x) < 60, abs(refine.columns.2.y) < 60, abs(refine.columns.0.x - 1) < 0.15, abs(refine.columns.1.y - 1) < 0.15 {
            return refine * coarse
        }
        return coarse
    }

    /// Greyscale thumbnail of an image (origin at 0,0), for alignment search.
    static func luma(_ image: CIImage, width: Int) -> (pixels: [Float], w: Int, h: Int, scale: CGFloat) {
        let e = image.extent
        let scale = CGFloat(width) / e.width
        let h = max(1, Int(e.height * scale))
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        var px = [Float](repeating: 0, count: width * h)
        RenderEngine.shared.context.render(small, toBitmap: &px, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: h),
                                           format: .Rf, colorSpace: nil)
        return (px, width, h, scale)
    }

    /// Mean absolute difference over the overlap when `floating` is shifted by (dx, dy) in full-size pixels.
    static func matchError(_ floating: CIImage, _ reference: CIImage, dx: CGFloat, dy: CGFloat, width: Int = 160) -> Float {
        let a = luma(reference, width: width)
        let b = luma(floating, width: Int(CGFloat(width) * floating.extent.width / reference.extent.width))
        // (dx, dy) are Core Image (bottom-up) offsets; bitmaps are top-down.
        return sad(a, b, Int((dx * a.scale).rounded()), Int((-dy * a.scale).rounded())) ?? .greatestFiniteMagnitude
    }

    /// Zero-normalised mean absolute difference over the overlap (independent of exposure differences).
    static func sad(_ a: (pixels: [Float], w: Int, h: Int, scale: CGFloat), _ b: (pixels: [Float], w: Int, h: Int, scale: CGFloat),
                    _ dx: Int, _ dy: Int) -> Float? {
        // Reference pixel (x, y) ↔ floating pixel (x − dx, y − dy).
        let x0 = max(0, dx), x1 = min(a.w, b.w + dx), y0 = max(0, dy), y1 = min(a.h, b.h + dy)
        guard x1 - x0 > a.w / 6, y1 - y0 > a.h / 3 else { return nil }   // need a real overlap
        var sumA: Float = 0, sumB: Float = 0, sqA: Float = 0, sqB: Float = 0
        let n = Float((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { for x in x0..<x1 {
            let va = a.pixels[y * a.w + x], vb = b.pixels[(y - dy) * b.w + (x - dx)]
            sumA += va; sumB += vb; sqA += va * va; sqB += vb * vb
        } }
        let meanA = sumA / n, meanB = sumB / n
        let sdA = max(1e-4, (sqA / n - meanA * meanA).squareRoot()), sdB = max(1e-4, (sqB / n - meanB * meanB).squareRoot())
        var total: Float = 0
        for y in y0..<y1 { for x in x0..<x1 {
            total += abs((a.pixels[y * a.w + x] - meanA) / sdA - (b.pixels[(y - dy) * b.w + (x - dx)] - meanB) / sdB)
        } }
        return total / n
    }

    /// Coarse-to-fine translation search (full-size pixels, Core Image coordinates).
    static func searchTranslation(_ floating: CIImage, onto reference: CIImage) -> CGPoint? {
        var best: (dx: Int, dy: Int, err: Float)?
        let coarse = 64
        let a = luma(reference, width: coarse), b = luma(floating, width: Int(CGFloat(coarse) * floating.extent.width / reference.extent.width))
        for dy in -a.h...a.h { for dx in -a.w...a.w {
            if let e = sad(a, b, dx, dy), e < (best?.err ?? .greatestFiniteMagnitude) { best = (dx, dy, e) }
        } }
        guard var found = best else { return nil }
        // Refine at 4× resolution around the coarse answer.
        let fine = coarse * 4
        let fa = luma(reference, width: fine), fb = luma(floating, width: Int(CGFloat(fine) * floating.extent.width / reference.extent.width))
        let cx = found.dx * 4, cy = found.dy * 4
        found.err = .greatestFiniteMagnitude
        for dy in (cy - 5)...(cy + 5) { for dx in (cx - 5)...(cx + 5) {
            if let e = sad(fa, fb, dx, dy), e < found.err { found = (dx, dy, e) }
        } }
        // Bitmaps are top-down; Core Image is bottom-up.
        return CGPoint(x: CGFloat(found.dx) / fa.scale, y: -CGFloat(found.dy) / fa.scale)
    }

    /// Applies a homography by mapping the image corners (exact for projective transforms).
    static func warp(_ image: CIImage, _ h: simd_float3x3) -> CIImage {
        let e = image.extent
        func map(_ p: CGPoint) -> CGPoint {
            let v = h * SIMD3(Float(p.x), Float(p.y), 1)
            return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
        }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = map(CGPoint(x: e.minX, y: e.maxY)); filter.topRight = map(CGPoint(x: e.maxX, y: e.maxY))
        filter.bottomLeft = map(CGPoint(x: e.minX, y: e.minY)); filter.bottomRight = map(CGPoint(x: e.maxX, y: e.minY))
        return filter.outputImage ?? image
    }

    // MARK: HDR

    /// Merges bracketed exposures into one HDR image (linear, values above 1 kept), aligned to the middle exposure.
    public static func hdr(_ sources: [Source]) -> CIImage? {
        guard sources.count >= 2 else { return sources.first?.image }
        let sorted = sources.enumerated().sorted { ($0.element.exposure ?? Double($0.offset)) < ($1.element.exposure ?? Double($1.offset)) }.map(\.element)
        let refIndex = sorted.count / 2
        let reference = sorted[refIndex]
        let extent = reference.image.extent
        var numerator: CIImage?
        var denominator: CIImage?
        for (i, source) in sorted.enumerated() {
            var image = source.image
            if i != refIndex, let h = homography(image, onto: reference.image) { image = warp(image, h) }
            image = image.cropped(to: extent)
            // Scale to the reference exposure: radiance × (refExposure / thisExposure).
            let factor = (reference.exposure ?? 1) / max(1e-9, source.exposure ?? (reference.exposure ?? 1) * pow(2, Double(i - refIndex)))
            let radiance = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            let weight = wellExposedWeight(image).cropped(to: extent)
            let weighted = radiance.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
            numerator = numerator.map { weighted.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? weighted
            denominator = denominator.map { weight.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? weight
        }
        guard let numerator, let denominator else { return nil }
        // CIDivideBlendMode computes background ÷ input.
        return denominator.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: numerator])
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .cropped(to: extent)
    }

    /// Hat weight: high for mid-tones, low for clipped highlights and noisy shadows (never zero).
    static func wellExposedWeight(_ image: CIImage) -> CIImage {
        let size = 24
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        var i = 0
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let c = SIMD3(Float(r), Float(g), Float(b)) / Float(size - 1)
            let l = max(c.x, max(c.y, c.z))
            let w = 0.002 + simd_smoothstep(0.02, 0.2, l) * (1 - simd_smoothstep(0.85, 0.99, l))
            cube[i] = w; cube[i + 1] = w; cube[i + 2] = w; cube[i + 3] = 1
            i += 4
        } } }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(size)
        filter.cubeData = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return filter.outputImage ?? image
    }

    // MARK: Panorama

    /// Zero-normalised difference above which neighbouring frames are treated as not overlapping.
    static let maxPanoramaMatchError: Float = 0.45

    /// Stitches overlapping photos (in shooting order) into one image, cropped to the area with pixels.
    public static func panorama(_ images: [CIImage], projection: Projection = .perspective, engine: RenderEngine = .shared) -> CIImage? {
        guard images.count >= 2 else { return images.first }
        // Cylindrical: pre-warp each photo so horizontal pans become translations.
        let focal = images[0].extent.width * 1.1
        let inputs = projection == .cylindrical ? images.map { cylindrical($0, focal: focal) } : images
        // Chain homographies to the middle photo.
        let ref = inputs.count / 2
        var toRef = [simd_float3x3](repeating: matrix_identity_float3x3, count: inputs.count)
        // Neighbouring frames must genuinely overlap: the aligned overlap has to match well.
        func pair(_ a: CIImage, onto b: CIImage) -> simd_float3x3? {
            guard let h = homography(a, onto: b) else { return nil }
            let error = matchError(a, b, dx: CGFloat(h.columns.2.x / h.columns.2.z), dy: CGFloat(h.columns.2.y / h.columns.2.z))
            return error < maxPanoramaMatchError ? h : nil
        }
        if ref + 1 < inputs.count {
            for i in (ref + 1)..<inputs.count {
                guard let h = pair(inputs[i], onto: inputs[i - 1]) else { return nil }
                toRef[i] = toRef[i - 1] * h
            }
        }
        if ref > 0 {
            for i in stride(from: ref - 1, through: 0, by: -1) {
                guard let h = pair(inputs[i], onto: inputs[i + 1]) else { return nil }
                toRef[i] = toRef[i + 1] * h
            }
        }
        var numerator: CIImage?
        var denominator: CIImage?
        var coverage: CIImage?
        for (i, image) in inputs.enumerated() {
            let warped = warp(image, toRef[i])
            // Hard coverage (where this photo has pixels), for the auto-crop.
            let hard = warp(CIImage(color: .white).cropped(to: image.extent), toRef[i])
            coverage = coverage.map { hard.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? hard
            // Feather: weight falls off towards each photo's edges.
            let e = image.extent
            let inset = min(e.width, e.height) * 0.12
            // Grey ramp with opaque alpha (a blurred alpha would break the premultiplied division below).
            let feather = CIImage(color: .white).cropped(to: e.insetBy(dx: inset, dy: inset))
                .applyingGaussianBlur(sigma: Double(inset / 2))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                              "inputBiasVector": CIVector(x: 0.001, y: 0.001, z: 0.001, w: 1)])
                .cropped(to: e)
            let weight = warp(feather, toRef[i])
            let weighted = warped.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
            numerator = numerator.map { weighted.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? weighted
            denominator = denominator.map { weight.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? weight
        }
        guard let numerator, let denominator else { return nil }
        let blended = denominator.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: numerator])
        let crop = coveredRect(coverage ?? denominator, engine: engine)
        // (A bias in CIColorMatrix makes the extent infinite, so crop after it.)
        return blended
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// Cylindrical projection approximated with narrow perspective strips (Core Image has no runtime warp kernels).
    static func cylindrical(_ image: CIImage, focal f: CGFloat, strips: Int = 48) -> CIImage {
        let e = image.extent
        let cx = e.midX, cy = e.midY
        func project(_ p: CGPoint) -> CGPoint {
            let x = p.x - cx, theta = atan(x / f)
            return CGPoint(x: cx + f * theta, y: cy + (p.y - cy) * cos(theta))
        }
        var out: CIImage?
        let w = e.width / CGFloat(strips)
        for s in 0..<strips {
            let rect = CGRect(x: e.minX + CGFloat(s) * w, y: e.minY, width: w + 1, height: e.height).intersection(e)
            let filter = CIFilter.perspectiveTransform()
            filter.inputImage = image.cropped(to: rect)
            filter.topLeft = project(CGPoint(x: rect.minX, y: rect.maxY)); filter.topRight = project(CGPoint(x: rect.maxX, y: rect.maxY))
            filter.bottomLeft = project(CGPoint(x: rect.minX, y: rect.minY)); filter.bottomRight = project(CGPoint(x: rect.maxX, y: rect.minY))
            guard let piece = filter.outputImage else { continue }
            out = out.map { piece.composited(over: $0) } ?? piece
        }
        return out ?? image
    }

    /// Largest rectangle where every pixel is covered (trimmed from the bounding box, edge by edge).
    static func coveredRect(_ coverage: CIImage, engine: RenderEngine) -> CGRect {
        let e = coverage.extent.integral
        let scale = min(1, 400 / max(e.width, e.height))
        let w = max(1, Int(e.width * scale)), h = max(1, Int(e.height * scale))
        let small = coverage.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        var px = [UInt8](repeating: 0, count: w * h)
        engine.context.render(small, toBitmap: &px, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: nil)
        func covered(_ x: Int, _ y: Int) -> Bool { px[y * w + x] > 128 }
        var x0 = 0, x1 = w - 1, y0 = 0, y1 = h - 1
        while x0 < x1 && y0 < y1 {
            let left = (y0...y1).filter { !covered(x0, $0) }.count, right = (y0...y1).filter { !covered(x1, $0) }.count
            let bottom = (x0...x1).filter { !covered($0, y0) }.count, top = (x0...x1).filter { !covered($0, y1) }.count
            let worst = max(left, right, bottom, top)
            if worst == 0 { break }
            if worst == left { x0 += 1 } else if worst == right { x1 -= 1 } else if worst == bottom { y0 += 1 } else { y1 -= 1 }
        }
        return CGRect(x: e.minX + CGFloat(x0) / scale, y: e.minY + CGFloat(y0) / scale,
                      width: CGFloat(x1 - x0 + 1) / scale, height: CGFloat(y1 - y0 + 1) / scale).integral
    }
}

extension Merge {
    public enum Kind: Sendable, Equatable {
        case hdr
        case panorama(Projection)
        public var suffix: String { if case .hdr = self { "HDR" } else { "Pano" } }
    }

    /// Merges originals (files on disk) and returns the merged image (HDR keeps values above 1).
    public static func merged(_ kind: Kind, files: [URL], engine: RenderEngine = .shared) throws -> CIImage {
        switch kind {
        case .hdr:
            let sources = try files.map { try source($0, engine: engine) }
            guard let image = hdr(sources) else { throw MergeError.failed("The brackets couldn’t be aligned") }
            return image
        case .panorama(let projection):
            let images = try files.map { try engine.base($0, recipe: EditRecipe()) }
            guard let image = panorama(images, projection: projection, engine: engine) else {
                throw MergeError.failed("The photos don’t overlap enough to stitch")
            }
            return image
        }
    }

    /// Writes the merged file next to `directory`: HEIC (HDR with a gain map), metadata from the first photo.
    public static func write(_ image: CIImage, kind: Kind, first: URL, to directory: URL, engine: RenderEngine = .shared) throws -> URL {
        let base = first.deletingPathExtension().lastPathComponent
        let url = directory.appending(path: "\(base)-\(kind.suffix).heic")
        if case .hdr = kind {
            try engine.exportHDR(image, type: .heic, original: first, to: url)
        } else {
            try engine.exportHDR(image.applyingFilter("CIColorClamp"), type: .heic, original: first, to: url)
        }
        return url
    }

    public enum MergeError: LocalizedError {
        case failed(String)
        public var errorDescription: String? { if case .failed(let m) = self { m } else { nil } }
    }
}
