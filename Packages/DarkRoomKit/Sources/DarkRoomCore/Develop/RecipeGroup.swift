import Foundation

/// Groups of Develop settings, used by presets (partial presets), copy/paste and sync.
public enum RecipeGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case profile = "Profile & RAW", whiteBalance = "White Balance", tone = "Tone", presence = "Presence"
    case curve = "Tone Curve", mixer = "Colour Mixer", grading = "Colour Grading", detail = "Detail", effects = "Effects"
    case geometry = "Crop & Geometry"
    case masks = "Masks"
    case retouch = "Retouch"

    public var id: String { rawValue }

    /// Groups a preset includes by default (geometry is never part of a look).
    public static let looks: Set<RecipeGroup> = Set(allCases).subtracting([.geometry, .masks, .retouch])

    public func copy(from source: EditRecipe, to r: inout EditRecipe) {
        switch self {
        case .profile:
            r.profile = source.profile; r.profileAmount = source.profileAmount; r.raw = source.raw
            r.lutProfile = source.lutProfile; r.lutAmount = source.lutAmount
        case .whiteBalance:
            r.whiteBalance = source.whiteBalance; r.temperature = source.temperature; r.tint = source.tint
            r.neutralPoint = source.neutralPoint
        case .tone:
            r.exposure = source.exposure; r.contrast = source.contrast; r.highlights = source.highlights
            r.shadows = source.shadows; r.whites = source.whites; r.blacks = source.blacks
        case .presence:
            r.texture = source.texture; r.clarity = source.clarity; r.dehaze = source.dehaze
            r.vibrance = source.vibrance; r.saturation = source.saturation
        case .curve:
            r.parametric = source.parametric; r.curveRGB = source.curveRGB; r.curveRed = source.curveRed
            r.curveGreen = source.curveGreen; r.curveBlue = source.curveBlue
        case .mixer:
            r.hsl = source.hsl; r.monochrome = source.monochrome; r.bwMix = source.bwMix
        case .grading:
            r.grading = source.grading
        case .detail:
            r.sharpenAmount = source.sharpenAmount; r.sharpenRadius = source.sharpenRadius
            r.sharpenDetail = source.sharpenDetail; r.sharpenMasking = source.sharpenMasking
            r.noiseLuminance = source.noiseLuminance; r.noiseColor = source.noiseColor
        case .effects:
            r.vignetteAmount = source.vignetteAmount; r.vignetteMidpoint = source.vignetteMidpoint
            r.vignetteRoundness = source.vignetteRoundness; r.vignetteFeather = source.vignetteFeather
            r.grainAmount = source.grainAmount; r.grainSize = source.grainSize; r.grainRoughness = source.grainRoughness
        case .geometry:
            r.geometry = source.geometry
        case .masks:
            r.masks = source.masks
        case .retouch:
            r.retouch = source.retouch; r.redEye = source.redEye
        }
    }

    public func reset(_ r: inout EditRecipe) { copy(from: EditRecipe(), to: &r) }

    /// Groups whose settings differ from the defaults.
    public static func changed(in recipe: EditRecipe) -> Set<RecipeGroup> {
        Set(allCases.filter { group in
            var a = EditRecipe(), b = EditRecipe()
            group.copy(from: recipe, to: &a)
            group.copy(from: EditRecipe(), to: &b)
            return a.withoutSnapshots != b.withoutSnapshots
        })
    }
}

extension EditRecipe {
    /// Applies `preset` (only its `groups`) on top of `self`, scaled by `amount` (0…2, Lightroom's preset Amount).
    /// Numbers move from their defaults by `amount ×` the preset's change; curves are blended towards identity.
    public func applying(_ preset: EditRecipe, groups: Set<RecipeGroup>, amount: Double = 1) -> EditRecipe {
        let scaled = preset.scaled(by: amount)
        var result = self
        for group in groups { group.copy(from: scaled, to: &result) }
        return result
    }

    /// Every adjustment's distance from default multiplied by `factor`.
    public func scaled(by factor: Double) -> EditRecipe {
        guard factor != 1 else { return self }
        let d = EditRecipe()
        func s(_ v: Double, _ base: Double) -> Double { base + (v - base) * factor }
        var r = self
        r.profileAmount = s(profileAmount, d.profileAmount)
        r.lutAmount = s(lutAmount, d.lutAmount)
        // Relative white balance (-100…100) scales; absolute RAW Kelvin values are left as they are.
        if abs(temperature) <= 100 { r.temperature = s(temperature, 0) }
        r.tint = s(tint, 0)
        r.exposure = s(exposure, 0); r.contrast = s(contrast, 0); r.highlights = s(highlights, 0)
        r.shadows = s(shadows, 0); r.whites = s(whites, 0); r.blacks = s(blacks, 0)
        r.texture = s(texture, 0); r.clarity = s(clarity, 0); r.dehaze = s(dehaze, 0)
        r.vibrance = s(vibrance, 0); r.saturation = s(saturation, 0)
        r.parametric.highlights = s(parametric.highlights, 0); r.parametric.lights = s(parametric.lights, 0)
        r.parametric.darks = s(parametric.darks, 0); r.parametric.shadows = s(parametric.shadows, 0)
        func curve(_ points: [CurvePoint]) -> [CurvePoint] {
            points.map { CurvePoint($0.x, min(1, max(0, $0.x + ($0.y - $0.x) * factor))) }
        }
        r.curveRGB = curve(curveRGB); r.curveRed = curve(curveRed); r.curveGreen = curve(curveGreen); r.curveBlue = curve(curveBlue)
        r.hsl = hsl.mapValues { HSLShift(hue: $0.hue * factor, saturation: $0.saturation * factor, luminance: $0.luminance * factor) }
        r.bwMix = bwMix.mapValues { $0 * factor }
        func wheel(_ w: Wheel) -> Wheel { Wheel(hue: w.hue, saturation: min(100, w.saturation * factor), luminance: w.luminance * factor) }
        r.grading.shadows = wheel(grading.shadows); r.grading.midtones = wheel(grading.midtones)
        r.grading.highlights = wheel(grading.highlights); r.grading.global = wheel(grading.global)
        r.sharpenAmount = s(sharpenAmount, d.sharpenAmount)
        r.noiseLuminance = s(noiseLuminance, 0); r.noiseColor = s(noiseColor, 0)
        r.vignetteAmount = s(vignetteAmount, 0)
        r.grainAmount = s(grainAmount, 0)
        if factor <= 0 { r.monochrome = false }
        return r
    }
}
