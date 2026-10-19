import Foundation
import Testing
import simd
@testable import DarkRoomCore

@Suite("Presets, LUTs and Lightroom import")
struct PresetTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "darkroom-presets-\(UUID().uuidString)")

    @Test func amountScalesAndPartialPresetsStack() {
        var warm = EditRecipe(); warm.temperature = 20; warm.tint = 4
        let warmPreset = Preset(name: "Warm", folder: "T", recipe: warm)
        #expect(warmPreset.groups == [.whiteBalance])
        var vignette = EditRecipe(); vignette.vignetteAmount = -30
        let vignettePreset = Preset(name: "Vig", folder: "T", recipe: vignette)

        var base = EditRecipe(); base.exposure = 0.5
        let half = warmPreset.apply(to: base, amount: 0.5)
        #expect(half.temperature == 10 && half.tint == 2)
        #expect(half.exposure == 0.5, "Other groups untouched")
        let both = vignettePreset.apply(to: warmPreset.apply(to: base))
        #expect(both.temperature == 20 && both.vignetteAmount == -30 && both.exposure == 0.5)
        let double = warmPreset.apply(to: base, amount: 2)
        #expect(double.temperature == 40)
        var curve = EditRecipe(); curve.curveRGB = [.init(0, 0.1), .init(1, 1)]
        let soft = curve.scaled(by: 0.5)
        #expect(abs(soft.curveRGB[0].y - 0.05) < 1e-9)
    }

    @Test func builtInsAreDistinctAndStable() {
        let presets = BuiltInPresets.all
        #expect(presets.count >= 40)
        #expect(Set(presets.map(\.id)).count == presets.count)
        #expect(presets.allSatisfy { p in !p.groups.isEmpty })
        #expect(BuiltInPresets.id("Color", "Warm") == BuiltInPresets.id("Color", "Warm"))
        #expect(presets.filter { $0.folder == "Video-safe" }.allSatisfy { p in p.videoSafe })
    }

    @Test func cubeParsesAndBuiltInLooksBake() throws {
        // 2×2×2 identity cube with a domain.
        var text = "TITLE \"id\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(r) \(g) \(b)\n" } } }
        let lut = try LUT.parseCube(text, id: "t", name: "Identity")
        #expect(lut.size == 2)
        let floats = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(floats.count == 32)
        #expect(floats[4] == 1 && floats[5] == 0 && floats[6] == 0, "Second entry is pure red")
        #expect(throws: LUT.LUTError.self) { try LUT.parseCube("LUT_1D_SIZE 4\n0 0 0", id: "x", name: "x") }
        let look = try #require(LUTLibrary.shared.lut("builtin.fuji.velvia"))
        #expect(look.size == 33)
    }

    @Test func lightroomXMPMapsSettingsAndReportsTheRest() throws {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:Exposure2012="+0.50" crs:Contrast2012="+15" crs:Highlights2012="-40" crs:Shadows2012="+30"
          crs:Vibrance="+20" crs:IncrementalTemperature="+10" crs:SaturationAdjustmentBlue="-25"
          crs:ColorGradeShadowHue="210" crs:ColorGradeShadowSat="20" crs:ConvertToGrayscale="False"
          crs:LensProfileEnable="1" crs:PostCropVignetteAmount="-18">
          <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Moody Blue</rdf:li></rdf:Alt></crs:Name>
          <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 20</rdf:li><rdf:li>128, 128</rdf:li><rdf:li>255, 240</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let (r, report, name) = try LightroomXMP.parse(Data(xmp.utf8), fallbackName: "file")
        #expect(name == "Moody Blue")
        #expect(r.exposure == 0.5 && r.contrast == 15 && r.highlights == -40 && r.shadows == 30 && r.vibrance == 20)
        #expect(r.temperature == 10)
        #expect(r.hsl[.blue]?.saturation == -25)
        #expect(r.grading.shadows.hue == 210 && r.grading.shadows.saturation == 20)
        #expect(r.vignetteAmount == -18)
        #expect(r.curveRGB.count == 3 && abs(r.curveRGB[0].y - 20.0 / 255) < 1e-9)
        #expect(report.joined().contains("LensProfileEnable"))
    }

    @Test func exportImportRoundTripAndCameraDefaults() throws {
        let store = PresetStore(file: dir.appending(path: "presets.json"))
        LUTLibrary.shared.load(directory: dir.appending(path: "luts"))
        var r = EditRecipe(); r.clarity = 22; r.vignetteAmount = -10
        let mine = Preset(name: "Mine", folder: "My Presets", recipe: r)
        store.save(mine)
        store.toggleFavorite(mine.id)
        store.setShortcut(1, for: mine.id)
        let data = try store.export([mine])
        #expect(String(decoding: data, as: UTF8.self).contains("\"format\" : \"darkroom-preset\""))
        let file = dir.appending(path: "Mine.darkroom-preset")
        try data.write(to: file)
        let (imported, _) = try store.importFile(file)
        #expect(imported.first?.folder == "Imported")
        #expect(imported.first?.recipe.clarity == 22)
        #expect(imported.first?.id != mine.id)

        store.update { $0.cameraDefaults["Canon EOS R6"] = mine.id }
        #expect(store.cameraDefault(make: "Canon", model: "Canon EOS R6", lens: nil)?.id == mine.id)
        #expect(store.cameraDefault(make: "Apple", model: "iPhone 15 Pro", lens: nil) == nil)
        // Persisted.
        let reloaded = PresetStore(file: dir.appending(path: "presets.json"))
        #expect(reloaded.snapshot.shortcuts[1] == mine.id)
        #expect(reloaded.snapshot.favorites.contains(mine.id))
    }
}
