import Foundation

/// A 3D colour lookup table: imported `.cube` files and DarkRoom's built-in camera-matching looks.
public struct LUT: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var group: String
    public var size: Int
    /// RGBA Float32, red fastest (CIColorCube layout).
    public var data: Data

    /// Parses an Adobe/Resolve `.cube` file (3D only; DOMAIN_MIN/MAX honoured).
    public static func parseCube(_ text: String, id: String, name: String, group: String = "Imported") throws -> LUT {
        var size = 0
        var minV: [Float] = [0, 0, 0], maxV: [Float] = [1, 1, 1]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts.first {
            case "LUT_3D_SIZE": size = Int(parts[1]) ?? 0
            case "LUT_1D_SIZE": throw LUTError.unsupported("1D LUTs aren’t supported; use a 3D .cube")
            case "DOMAIN_MIN": minV = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX": maxV = parts.dropFirst().compactMap { Float($0) }
            default:
                let rgb = parts.compactMap { Float($0) }
                guard rgb.count == 3 else { continue }
                for c in 0..<3 {
                    let span = max(maxV[safe: c] ?? 1, 1e-6) - (minV[safe: c] ?? 0)
                    values.append(min(1, max(0, (rgb[c] - (minV[safe: c] ?? 0)) / span)))
                }
                values.append(1)
            }
        }
        guard size >= 2, values.count == size * size * size * 4 else { throw LUTError.unsupported("Not a valid 3D .cube file") }
        return LUT(id: id, name: name, group: group, size: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// Bakes a recipe's global colour (profile look, tone, HSL, grading…) into a LUT.
    public static func baked(_ recipe: EditRecipe, id: String, name: String, group: String, size: Int = 33) -> LUT {
        LUT(id: id, name: name, group: group, size: size, data: ColorTransform(recipe).cubeData(size: size))
    }

    public enum LUTError: LocalizedError {
        case unsupported(String)
        public var errorDescription: String? { if case .unsupported(let m) = self { m } else { nil } }
    }
}

/// Built-in LUT profiles plus the user's imported ones (stored per user on this Mac).
public final class LUTLibrary: @unchecked Sendable {
    public static let shared = LUTLibrary()
    private let lock = NSLock()
    private var imported: [String: LUT] = [:]
    private var builtInCache: [String: LUT] = [:]
    private var directory: URL?

    /// Loads a user's imported LUTs (call when a user signs in).
    public func load(directory: URL) {
        let luts = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "darkroomlut" }
            .compactMap { try? JSONDecoder().decode(LUT.self, from: Data(contentsOf: $0)) } ?? []
        lock.withLock {
            self.directory = directory
            imported = Dictionary(uniqueKeysWithValues: luts.map { ($0.id, $0) })
        }
    }

    public func add(_ lut: LUT) throws {
        let dir = lock.withLock { directory }
        if let dir {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(lut).write(to: dir.appending(path: "\(lut.id).darkroomlut"), options: .atomic)
        }
        lock.withLock { imported[lut.id] = lut }
    }

    public func remove(_ id: String) {
        let dir = lock.withLock { directory }
        if let dir { try? FileManager.default.removeItem(at: dir.appending(path: "\(id).darkroomlut")) }
        _ = lock.withLock { imported.removeValue(forKey: id) }
    }

    public var all: [LUT] {
        let user = lock.withLock { Array(imported.values) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Self.builtIns.map { lut($0.id)! } + user
    }

    public func lut(_ id: String) -> LUT? {
        if let user = lock.withLock({ imported[id] }) { return user }
        if let cached = lock.withLock({ builtInCache[id] }) { return cached }
        guard let def = Self.builtIns.first(where: { $0.id == id }) else { return nil }
        let baked = LUT.baked(def.recipe, id: def.id, name: def.name, group: def.group)
        lock.withLock { builtInCache[id] = baked }
        return baked
    }

    // MARK: Built-in camera-matching looks (best effort, not manufacturer-exact)

    struct BuiltIn { let id: String; let name: String; let group: String; let recipe: EditRecipe }

    static let builtIns: [BuiltIn] = {
        func look(_ id: String, _ name: String, _ group: String, _ build: (inout EditRecipe) -> Void) -> BuiltIn {
            var r = EditRecipe(); build(&r); return BuiltIn(id: "builtin.\(id)", name: name, group: group, recipe: r)
        }
        return [
            look("canon.standard", "Canon Standard", "Canon-style") { $0.contrast = 12; $0.saturation = 8; $0.hsl[.red] = .init(saturation: 6) },
            look("canon.portrait", "Canon Portrait", "Canon-style") { $0.contrast = 6; $0.hsl[.orange] = .init(saturation: -8, luminance: 6); $0.hsl[.red] = .init(saturation: -4) },
            look("canon.landscape", "Canon Landscape", "Canon-style") { $0.contrast = 14; $0.hsl[.green] = .init(saturation: 18); $0.hsl[.blue] = .init(saturation: 15, luminance: -6); $0.saturation = 6 },
            look("canon.neutral", "Canon Neutral", "Canon-style") { $0.contrast = -12; $0.saturation = -10 },
            look("canon.faithful", "Canon Faithful", "Canon-style") { $0.contrast = -6; $0.saturation = -4 },
            look("fuji.provia", "Provia-style", "Fujifilm-style") { $0.contrast = 10; $0.saturation = 6 },
            look("fuji.velvia", "Velvia-style", "Fujifilm-style") { $0.contrast = 22; $0.saturation = 28; $0.hsl[.green] = .init(saturation: 12); $0.hsl[.blue] = .init(luminance: -10) },
            look("fuji.astia", "Astia-style", "Fujifilm-style") { $0.contrast = 4; $0.hsl[.orange] = .init(saturation: -6, luminance: 5); $0.saturation = 4 },
            look("fuji.classicchrome", "Classic Chrome-style", "Fujifilm-style") {
                $0.contrast = 14; $0.saturation = -22; $0.blacks = 8
                $0.grading.shadows = .init(hue: 200, saturation: 12); $0.grading.highlights = .init(hue: 45, saturation: 8)
                $0.hsl[.blue] = .init(hue: -10, saturation: -15); $0.hsl[.red] = .init(saturation: -12)
            },
            look("fuji.acros", "Acros-style", "Fujifilm-style") { $0.monochrome = true; $0.contrast = 18; $0.bwMix[.red] = 10; $0.bwMix[.blue] = -10 },
            look("apple.standard", "iPhone Standard", "Apple-style") { $0.contrast = 8; $0.vibrance = 10; $0.parametric.shadows = 8 },
        ]
    }()
}
