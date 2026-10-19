import Foundation
import simd

/// Global colour and tone adjustments as a pure function of one colour, baked into a 3D LUT
/// (`CIColorCubeWithColorSpace`, gamma-encoded sRGB/P3 input). Pure Swift so it can be unit-tested.
public struct ColorTransform: Sendable {
    let recipe: EditRecipe
    private let rgbCurve: MonotoneCurve?
    private let redCurve: MonotoneCurve?
    private let greenCurve: MonotoneCurve?
    private let blueCurve: MonotoneCurve?
    private let look: Look

    public init(_ recipe: EditRecipe) {
        self.recipe = recipe
        func curve(_ points: [EditRecipe.CurvePoint]) -> MonotoneCurve? {
            points == EditRecipe.CurvePoint.identity ? nil : MonotoneCurve(points)
        }
        rgbCurve = curve(recipe.curveRGB)
        redCurve = curve(recipe.curveRed)
        greenCurve = curve(recipe.curveGreen)
        blueCurve = curve(recipe.curveBlue)
        look = Look(recipe.profile, amount: recipe.profileAmount / 100)
    }

    /// True if every global colour control is at its default (the LUT can be skipped).
    public var isIdentity: Bool {
        let r = recipe
        let toneIdentity: Bool = r.contrast == 0 && r.whites == 0 && r.blacks == 0 && r.parametric == EditRecipe.ParametricCurve()
        let curvesIdentity: Bool = rgbCurve == nil && redCurve == nil && greenCurve == nil && blueCurve == nil
        let colorIdentity: Bool = r.vibrance == 0 && r.saturation == 0 && r.hsl.values.allSatisfy(\.isZero) && !r.monochrome
        return toneIdentity && curvesIdentity && colorIdentity && r.grading == EditRecipe.ColorGrading() && look.isIdentity
            && r.calibration.isIdentity
    }

    /// Applies the transform to a gamma-encoded RGB colour in 0…1.
    public func apply(_ input: SIMD3<Float>) -> SIMD3<Float> {
        var c = simd_clamp(input, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let r = recipe

        // Calibration (camera primaries and shadow tint), then the profile look, scaled by Profile amount.
        if !r.calibration.isIdentity { c = calibrate(c) }
        c = look.apply(c)

        // Tone: contrast, whites/blacks, parametric curve applied to luminance-preserving ratios.
        if r.contrast != 0 || r.whites != 0 || r.blacks != 0 || r.parametric != EditRecipe.ParametricCurve() {
            c = SIMD3(tone(c.x), tone(c.y), tone(c.z))
        }

        // Point curves: master, then per channel.
        if let rgbCurve { c = SIMD3(rgbCurve(c.x), rgbCurve(c.y), rgbCurve(c.z)) }
        if let redCurve { c.x = redCurve(c.x) }
        if let greenCurve { c.y = greenCurve(c.y) }
        if let blueCurve { c.z = blueCurve(c.z) }

        // Colour mixer, vibrance, saturation, B&W in HSL space.
        var hsl = ColorTransform.rgbToHSL(c)
        if !r.hsl.isEmpty && !r.monochrome { hsl = applyHSL(hsl) }
        if r.vibrance != 0 {
            let v = Float(r.vibrance / 100)
            // Lifts muted colours most and protects already-saturated (and skin) tones.
            let skin: Float = Self.bandWeight(hue: hsl.x, centre: 25, width: 30)
            let gain = v * (1 - hsl.y) * (v > 0 ? (1 - 0.5 * skin) : 1)
            hsl.y = simd_clamp(hsl.y * (1 + gain), 0, 1)
        }
        if r.saturation != 0 { hsl.y = simd_clamp(hsl.y * (1 + Float(r.saturation / 100)), 0, 1) }
        c = ColorTransform.hslToRGB(hsl)
        if r.monochrome { c = SIMD3(repeating: monochromeValue(c, hsl: hsl)) }

        // Colour grading.
        if r.grading != EditRecipe.ColorGrading() { c = grade(c) }

        return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    // MARK: Calibration

    /// Broad primary-based hue/saturation shifts (like Lightroom's Calibration panel) and a shadow tint.
    func calibrate(_ input: SIMD3<Float>) -> SIMD3<Float> {
        let cal = recipe.calibration
        var hsl = ColorTransform.rgbToHSL(input)
        let hue = hsl.x * 360
        var hueShift: Float = 0, satScale: Float = 0
        for (centre, h, sat) in [(Float(0), cal.redHue, cal.redSaturation), (120, cal.greenHue, cal.greenSaturation), (240, cal.blueHue, cal.blueSaturation)] {
            let w = ColorTransform.bandWeight(hue: hue, centre: centre, width: 120)
            hueShift += w * Float(h / 100) * 20
            satScale += w * Float(sat / 100)
        }
        hsl.x = ((hue + hueShift).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        hsl.y = simd_clamp(hsl.y * (1 + satScale), 0, 1)
        var c = ColorTransform.hslToRGB(hsl)
        if cal.shadowTint != 0 {
            let luma = simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722))
            let w = powf(1 - luma, 2) * Float(cal.shadowTint / 100) * 0.08
            c += SIMD3(w, -w, w)
        }
        return c
    }

    // MARK: Tone

    func tone(_ x: Float) -> Float {
        let r = recipe
        var y = x
        if r.contrast != 0 {
            // S-curve around mid-grey; stays monotone for |amount| ≤ 1.
            let a = Float(r.contrast / 100) * 0.9
            y = y + a * 2 * y * (1 - y) * (2 * y - 1) * (a > 0 ? 1 : 0.8)
        }
        if r.blacks != 0 { let b = Float(r.blacks / 100); y += b * 0.18 * powf(1 - y, 4) }
        if r.whites != 0 { let w = Float(r.whites / 100); y += w * 0.18 * powf(y, 4) }
        let p = r.parametric
        if p != EditRecipe.ParametricCurve() {
            let s1 = Float(p.split1 / 100), s2 = Float(p.split2 / 100), s3 = Float(p.split3 / 100)
            let regions: [(Double, Float, Float)] = [(p.shadows, 0, s1), (p.darks, s1, s2), (p.lights, s2, s3), (p.highlights, s3, 1)]
            for (amount, lo, hi) in regions where amount != 0 {
                let centre = (lo + hi) / 2, half = max((hi - lo), 0.1)
                let t = (y - centre) / half
                let bump = abs(t) < 1 ? 0.5 * (1 + cosf(.pi * t)) : 0
                y += Float(amount / 100) * 0.2 * bump * min(y, 1 - y) * 2.2
            }
        }
        return simd_clamp(y, 0, 1)
    }

    // MARK: Colour mixer

    func applyHSL(_ hsl: SIMD3<Float>) -> SIMD3<Float> {
        var out = hsl
        let hueDeg = hsl.x * 360
        var hueShift: Float = 0, satScale: Float = 0, lumShift: Float = 0
        for band in EditRecipe.ColorBand.allCases {
            guard let shift = recipe.hsl[band], !shift.isZero else { continue }
            let w = Self.bandWeight(hue: hueDeg, centre: Float(band.hue), width: Self.bandWidth(band))
            guard w > 0 else { continue }
            hueShift += w * Float(shift.hue / 100) * 30
            satScale += w * Float(shift.saturation / 100)
            lumShift += w * Float(shift.luminance / 100)
        }
        out.x = (hueDeg + hueShift).truncatingRemainder(dividingBy: 360) / 360
        if out.x < 0 { out.x += 1 }
        out.y = simd_clamp(hsl.y * (1 + satScale), 0, 1)
        // Luminance changes only affect coloured pixels (greys stay put).
        out.z = simd_clamp(hsl.z + lumShift * 0.35 * hsl.y * (1 - abs(2 * hsl.z - 1) * 0.5), 0, 1)
        return out
    }

    /// Smooth (raised-cosine) weight for a hue band.
    static func bandWeight(hue: Float, centre: Float, width: Float) -> Float {
        var d = abs(hue - centre).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        guard d < width else { return 0 }
        return 0.5 * (1 + cosf(.pi * d / width))
    }

    /// Distance to the farther neighbouring band centre, so adjacent weights overlap and sum smoothly.
    static func bandWidth(_ band: EditRecipe.ColorBand) -> Float {
        let all = EditRecipe.ColorBand.allCases
        let i = all.firstIndex(of: band)!
        let prev = all[(i + all.count - 1) % all.count].hue, next = all[(i + 1) % all.count].hue
        func dist(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return d > 180 ? 360 - d : d }
        return Float(max(dist(band.hue, prev), dist(band.hue, next)))
    }

    // MARK: Black & white

    func monochromeValue(_ c: SIMD3<Float>, hsl: SIMD3<Float>) -> Float {
        var y = simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722))
        let hueDeg = hsl.x * 360
        for band in EditRecipe.ColorBand.allCases {
            guard let mix = recipe.bwMix[band], mix != 0 else { continue }
            let w = Self.bandWeight(hue: hueDeg, centre: Float(band.hue), width: Self.bandWidth(band))
            y += w * Float(mix / 100) * 0.4 * hsl.y * (0.25 + y)
        }
        return simd_clamp(y, 0, 1)
    }

    // MARK: Colour grading

    func grade(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let g = recipe.grading
        let luma = simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722))
        let blend = Float(g.blending / 100), balance = Float(g.balance / 100)
        // Region weights; Balance moves the shadow/highlight split, Blending widens the overlap.
        let pivot = simd_clamp(0.5 - balance * 0.35, 0.1, 0.9)
        let softness = 0.15 + 0.6 * blend
        let ws = simd_smoothstep(pivot + softness * 0.5, pivot - softness * 0.5 - 0.25, luma)
        let wh = simd_smoothstep(pivot - softness * 0.5, pivot + softness * 0.5 + 0.25, luma)
        let wm = max(0, 1 - ws - wh)
        var out = c
        for (wheel, weight) in [(g.shadows, ws), (g.midtones, wm), (g.highlights, wh), (g.global, Float(1))] {
            guard weight > 0, wheel.saturation != 0 || wheel.luminance != 0 else { continue }
            let tint = ColorTransform.hslToRGB(SIMD3(Float(wheel.hue / 360), 1, 0.5)) - SIMD3(repeating: 0.5)
            out += tint * Float(wheel.saturation / 100) * 0.3 * weight
            out += SIMD3(repeating: Float(wheel.luminance / 100) * 0.25 * weight)
        }
        return out
    }

    // MARK: HSL conversion

    static func rgbToHSL(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let maxV = max(c.x, max(c.y, c.z)), minV = min(c.x, min(c.y, c.z))
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 1e-6 else { return SIMD3(0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Float
        if maxV == c.x { h = (c.y - c.z) / d + (c.y < c.z ? 6 : 0) }
        else if maxV == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        return SIMD3(h / 6, s, l)
    }

    static func hslToRGB(_ hsl: SIMD3<Float>) -> SIMD3<Float> {
        let (h, s, l) = (hsl.x, hsl.y, hsl.z)
        guard s > 1e-6 else { return SIMD3(repeating: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Float) -> Float {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return SIMD3(channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    // MARK: LUT

    /// RGBA float cube data for `CIColorCubeWithColorSpace` (red varies fastest).
    public func cubeData(size: Int = 33) -> Data {
        var values = [Float](repeating: 0, count: size * size * size * 4)
        let scale = 1 / Float(size - 1)
        var i = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = apply(SIMD3(Float(r) * scale, Float(g) * scale, Float(b) * scale))
                    values[i] = out.x; values[i + 1] = out.y; values[i + 2] = out.z; values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Profile looks (DarkRoom's own, built from the same controls so they stay neutral to the camera).
struct Look: Sendable {
    let profile: EditRecipe.Profile
    let amount: Float

    init(_ profile: EditRecipe.Profile, amount: Double) {
        self.profile = profile
        self.amount = Float(amount)
    }

    var isIdentity: Bool { profile == .standard || profile == .linear || amount == 0 }

    func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        guard !isIdentity else { return c }
        var hsl = ColorTransform.rgbToHSL(c)
        func s(_ x: Float) -> Float { x * amount }
        switch profile {
        case .neutral:
            hsl.y *= 1 - s(0.12)
            hsl.z = hsl.z + s(0.08) * (0.5 - hsl.z) * 2 * hsl.z * (1 - hsl.z) * 2
        case .vivid:
            hsl.y = min(1, hsl.y * (1 + s(0.28)))
            hsl.z = hsl.z + s(0.1) * 2 * hsl.z * (1 - hsl.z) * (2 * hsl.z - 1)
        case .landscape:
            let foliage = ColorTransform.bandWeight(hue: hsl.x * 360, centre: 100, width: 70)
            let sky = ColorTransform.bandWeight(hue: hsl.x * 360, centre: 215, width: 50)
            hsl.y = min(1, hsl.y * (1 + s(0.25) * (foliage + sky) + s(0.06)))
            hsl.z -= s(0.04) * sky * hsl.y
        case .portrait:
            let skin = ColorTransform.bandWeight(hue: hsl.x * 360, centre: 25, width: 30)
            hsl.y *= 1 - s(0.12) * skin
            hsl.z = min(1, hsl.z + s(0.03) * skin)
        case .monochrome:
            hsl.y *= 1 - amount
        case .standard, .linear:
            break
        }
        return ColorTransform.hslToRGB(hsl)
    }
}

/// Monotone cubic interpolation (Fritsch–Carlson) through curve points; never overshoots.
struct MonotoneCurve: Equatable, Sendable {
    let xs: [Float], ys: [Float], ms: [Float]

    init(_ points: [EditRecipe.CurvePoint]) {
        let sorted = points.sorted { $0.x < $1.x }
        var xs = sorted.map { Float($0.x) }, ys = sorted.map { Float($0.y) }
        if xs.count < 2 { xs = [0, 1]; ys = [0, 1] }
        let n = xs.count
        var deltas = [Float](repeating: 0, count: n - 1)
        for i in 0..<n - 1 { deltas[i] = (ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], 1e-6) }
        var ms = [Float](repeating: 0, count: n)
        ms[0] = deltas[0]; ms[n - 1] = deltas[n - 2]
        for i in 1..<n - 1 { ms[i] = deltas[i - 1] * deltas[i] <= 0 ? 0 : (deltas[i - 1] + deltas[i]) / 2 }
        for i in 0..<n - 1 where deltas[i] == 0 { ms[i] = 0; ms[i + 1] = 0 }
        for i in 0..<n - 1 where deltas[i] != 0 {
            let a = ms[i] / deltas[i], b = ms[i + 1] / deltas[i]
            let h = a * a + b * b
            if h > 9 { let t = 3 / sqrtf(h); ms[i] = t * a * deltas[i]; ms[i + 1] = t * b * deltas[i] }
        }
        self.xs = xs; self.ys = ys; self.ms = ms
    }

    func callAsFunction(_ x: Float) -> Float {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i]
            + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
        return simd_clamp(y, 0, 1)
    }
}
