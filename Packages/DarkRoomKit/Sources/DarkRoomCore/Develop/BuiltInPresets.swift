import Foundation
import CryptoKit

/// DarkRoom's built-in presets (editable as copies). Partial presets touch only the groups they change.
public enum BuiltInPresets {
    /// Stable id from the folder and name, so favourites and shortcuts survive app updates.
    static func id(_ folder: String, _ name: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data("darkroom.builtin.\(folder).\(name)".utf8))
        let b = Array(digest)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6] & 0x0F | 0x30, b[7], b[8] & 0x3F | 0x80, b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func make(_ folder: String, _ name: String, _ build: (inout EditRecipe) -> Void) -> Preset {
        var r = EditRecipe()
        build(&r)
        return Preset(id: id(folder, name), name: name, folder: folder, recipe: r, isBuiltIn: true)
    }

    public static let all: [Preset] = [
        // Auto / Basic
        make("Basic", "Brighten") { $0.exposure = 0.45; $0.shadows = 15 },
        make("Basic", "Lift Shadows") { $0.shadows = 45; $0.blacks = 8 },
        make("Basic", "Recover Highlights") { $0.highlights = -60; $0.whites = -12 },
        make("Basic", "Clarity") { $0.clarity = 30; $0.texture = 15 },
        make("Basic", "Punch") { $0.contrast = 20; $0.clarity = 15; $0.vibrance = 20 },
        make("Basic", "Soft & Clean") { $0.contrast = -10; $0.highlights = -20; $0.shadows = 20; $0.clarity = -8 },
        // Colour
        make("Color", "Warm") { $0.temperature = 18; $0.tint = 3 },
        make("Color", "Cool") { $0.temperature = -18 },
        make("Color", "Vivid") { $0.vibrance = 35; $0.saturation = 10; $0.contrast = 10 },
        make("Color", "Muted") { $0.saturation = -30; $0.vibrance = -10; $0.blacks = 10 },
        make("Color", "Golden Hour") {
            $0.temperature = 25; $0.grading.highlights = .init(hue: 45, saturation: 25); $0.grading.shadows = .init(hue: 25, saturation: 10)
            $0.vibrance = 15; $0.highlights = -15
        },
        make("Color", "Teal & Orange") {
            $0.grading.shadows = .init(hue: 190, saturation: 30); $0.grading.highlights = .init(hue: 35, saturation: 25)
            $0.hsl[.orange] = .init(saturation: 10); $0.hsl[.aqua] = .init(hue: 10, saturation: 15); $0.contrast = 12
        },
        make("Color", "Soft Pastel") {
            $0.contrast = -20; $0.saturation = -15; $0.blacks = 25; $0.highlights = -20
            $0.grading.highlights = .init(hue: 330, saturation: 8); $0.curveRGB = [.init(0, 0.08), .init(0.5, 0.52), .init(1, 0.96)]
        },
        // Black & white
        make("B&W", "Neutral") { $0.monochrome = true },
        make("B&W", "High Contrast") { $0.monochrome = true; $0.contrast = 45; $0.clarity = 20; $0.blacks = -15; $0.whites = 15 },
        make("B&W", "Soft") { $0.monochrome = true; $0.contrast = -20; $0.highlights = -20; $0.shadows = 20 },
        make("B&W", "Selenium") { $0.monochrome = true; $0.contrast = 15; $0.grading.shadows = .init(hue: 280, saturation: 18) },
        make("B&W", "Sepia") { $0.monochrome = true; $0.grading.global = .init(hue: 35, saturation: 25); $0.contrast = 5 },
        make("B&W", "Infrared Look") {
            $0.monochrome = true; $0.bwMix[.green] = 80; $0.bwMix[.yellow] = 60; $0.bwMix[.blue] = -60; $0.contrast = 25; $0.clarity = -10
        },
        // Film
        make("Film", "Classic Chrome-style") { $0.lutProfile = "builtin.fuji.classicchrome"; $0.grainAmount = 12 },
        make("Film", "Portra-style") {
            $0.contrast = -8; $0.temperature = 8; $0.hsl[.orange] = .init(hue: -4, saturation: -8, luminance: 8)
            $0.hsl[.green] = .init(hue: 15, saturation: -20); $0.curveRGB = [.init(0, 0.05), .init(0.25, 0.25), .init(0.75, 0.78), .init(1, 0.97)]
            $0.grainAmount = 15
        },
        make("Film", "Ektar-style") { $0.contrast = 18; $0.saturation = 18; $0.hsl[.red] = .init(saturation: 12); $0.hsl[.blue] = .init(saturation: 12); $0.grainAmount = 10 },
        make("Film", "Velvia-style") { $0.lutProfile = "builtin.fuji.velvia"; $0.blacks = -10 },
        make("Film", "Faded Matte") {
            $0.curveRGB = [.init(0, 0.12), .init(0.3, 0.3), .init(0.75, 0.74), .init(1, 0.94)]; $0.saturation = -12; $0.contrast = -5
            $0.grainAmount = 18
        },
        make("Film", "Cross Process") {
            $0.curveRed = [.init(0, 0), .init(0.25, 0.2), .init(0.75, 0.82), .init(1, 1)]
            $0.curveBlue = [.init(0, 0.12), .init(0.5, 0.45), .init(1, 0.85)]; $0.saturation = 15; $0.contrast = 15
        },
        // Portrait
        make("Portrait", "Natural Skin") { $0.hsl[.orange] = .init(saturation: -10, luminance: 10); $0.hsl[.red] = .init(saturation: -6); $0.texture = -12; $0.clarity = -5 },
        make("Portrait", "Bright & Airy") { $0.exposure = 0.5; $0.contrast = -15; $0.highlights = -25; $0.shadows = 30; $0.temperature = 5; $0.vibrance = 10 },
        make("Portrait", "Moody") {
            $0.exposure = -0.3; $0.contrast = 15; $0.saturation = -20; $0.blacks = 15; $0.grading.shadows = .init(hue: 210, saturation: 15)
            $0.vignetteAmount = -20
        },
        // Landscape
        make("Landscape", "Vivid Sky") { $0.hsl[.blue] = .init(saturation: 25, luminance: -20); $0.hsl[.aqua] = .init(saturation: 15); $0.dehaze = 15; $0.highlights = -25 },
        make("Landscape", "Foliage Pop") { $0.hsl[.green] = .init(hue: 8, saturation: 25, luminance: 5); $0.hsl[.yellow] = .init(saturation: 15); $0.vibrance = 15 },
        make("Landscape", "Dramatic") { $0.contrast = 25; $0.clarity = 30; $0.dehaze = 20; $0.highlights = -40; $0.shadows = 25; $0.vignetteAmount = -15 },
        make("Landscape", "Haze Cut") { $0.dehaze = 35; $0.contrast = 8; $0.vibrance = 10 },
        // Detail
        make("Detail", "Sharpen (Screen)") { $0.sharpenAmount = 50; $0.sharpenRadius = 0.8; $0.sharpenDetail = 25; $0.sharpenMasking = 30 },
        make("Detail", "Noise Clean-up") { $0.noiseLuminance = 35; $0.noiseColor = 30; $0.sharpenAmount = 30; $0.sharpenMasking = 50 },
        // Effects
        make("Effects", "Vignette") { $0.vignetteAmount = -25 },
        make("Effects", "Grain") { $0.grainAmount = 25; $0.grainSize = 30 },
        // Video-safe (no grain or vignette)
        make("Video-safe", "Video Warm") { $0.temperature = 15; $0.vibrance = 10 },
        make("Video-safe", "Video Cool") { $0.temperature = -15 },
        make("Video-safe", "Video Punch") { $0.contrast = 15; $0.vibrance = 20 },
        make("Video-safe", "Video B&W") { $0.monochrome = true; $0.contrast = 15 },
    ]
}
