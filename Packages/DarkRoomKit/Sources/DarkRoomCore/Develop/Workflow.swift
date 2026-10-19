import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import AppKit
import ImmichAPI

// MARK: Culling flags (Immich tags Culling/Pick and Culling/Reject)

public enum CullFlag: String, Sendable, CaseIterable { case pick = "Culling/Pick", reject = "Culling/Reject" }

public struct Culling: Sendable {
    public let client: ImmichClient
    public init(client: ImmichClient) { self.client = client }

    /// The tag ids for Pick and Reject (created on first use).
    public func tagIDs() async throws -> [CullFlag: String] {
        let tags = try await client.upsertTags(body: TagUpsertDto(tags: CullFlag.allCases.map(\.rawValue)))
        var out: [CullFlag: String] = [:]
        for flag in CullFlag.allCases { out[flag] = tags.first { $0.value == flag.rawValue }?.id }
        return out
    }

    /// Sets (or clears, with nil) the flag on assets. Undo restores each asset's previous flag.
    public func setFlag(_ flag: CullFlag?, on ids: [String]) async throws -> UndoAction {
        let tags = try await tagIDs()
        guard let pick = tags[.pick], let reject = tags[.reject] else { throw CocoaError(.featureUnsupported) }
        var previous: [String: CullFlag?] = [:]
        for id in ids {
            let asset = try await client.getAssetInfo(id: id)
            let values = Set((asset.tags ?? []).map(\.value))
            previous[id] = values.contains(CullFlag.pick.rawValue) ? .pick : (values.contains(CullFlag.reject.rawValue) ? .reject : nil)
        }
        try await apply(flag, ids, pick: pick, reject: reject)
        let client = self.client
        let before = previous
        return UndoAction(name: flag == .pick ? "Pick" : (flag == .reject ? "Reject" : "Unflag")) {
            let me = Culling(client: client)
            for (id, old) in before { try await me.apply(old, [id], pick: pick, reject: reject) }
        }
    }

    func apply(_ flag: CullFlag?, _ ids: [String], pick: String, reject: String) async throws {
        switch flag {
        case .pick:
            try await TagRemoval.remove(reject, from: ids, client: client)
            TagRemoval.added([pick], to: ids)
            _ = try await client.tagAssets(id: pick, body: BulkIdsDto(ids: ids))
        case .reject:
            try await TagRemoval.remove(pick, from: ids, client: client)
            TagRemoval.added([reject], to: ids)
            _ = try await client.tagAssets(id: reject, body: BulkIdsDto(ids: ids))
        case nil:
            try await TagRemoval.remove(pick, from: ids, client: client)
            try await TagRemoval.remove(reject, from: ids, client: client)
        }
    }

    /// Assets carrying a flag (for filters and "Trash all rejects").
    public func assets(flagged flag: CullFlag) async throws -> [AssetResponseDto] {
        guard let tag = try await tagIDs()[flag] else { return [] }
        var all: [AssetResponseDto] = []
        var page = 1
        while true {
            let r = try await client.searchAssets(body: MetadataSearchDto(page: page, size: 500, tagIds: [tag], withExif: true))
            all += r.assets.items
            guard let next = r.assets.nextPage.flatMap(Int.init), next > page else { break }
            page = next
        }
        return all
    }
}

// MARK: Export

public struct ExportSettings: Codable, Hashable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable { case jpeg = "JPEG", heic = "HEIC", png = "PNG", tiff = "TIFF", original = "Original" }
    public enum Metadata: String, Codable, CaseIterable, Sendable { case all = "All", noLocation = "All except location", none = "Copyright only" }
    public enum ColorSpace: String, Codable, CaseIterable, Sendable { case sRGB, displayP3 = "Display P3", adobeRGB = "Adobe RGB", proPhoto = "ProPhoto RGB" }
    public enum WatermarkPosition: String, Codable, CaseIterable, Sendable { case bottomRight = "Bottom right", bottomLeft = "Bottom left", topRight = "Top right", topLeft = "Top left", center = "Centre" }

    public var name = "Default"
    public var format: Format = .jpeg
    /// Long edge in pixels (nil = full size).
    public var longEdge: Int?
    public var quality: Double = 0.9
    public var colorSpace: ColorSpace = .sRGB
    public var sixteenBit = false
    public var metadata: Metadata = .all
    public var copyright = ""
    public var watermarkText = ""
    public var watermarkImage: String?          // file path
    public var watermarkSize: Double = 4        // % of the long edge
    public var watermarkOpacity: Double = 70
    public var watermarkPosition: WatermarkPosition = .bottomRight
    /// Tokens: {name} {date} {seq} {camera}.
    public var naming = "{name}"
    /// Use the edited version (DarkRoom/Immich edits) rather than the untouched original.
    public var edited = true
    public init() {}
}

public enum Exporter {
    /// Renders one image file to `folder` with the settings; returns the written file.
    public static func export(_ source: URL, settings: ExportSettings, folder: URL, sequence: Int, engine: RenderEngine = .shared) throws -> URL {
        let originalName = source.deletingPathExtension().lastPathComponent
        let props = RenderEngine.metadata(of: source)
        if settings.format == .original && settings.longEdge == nil && settings.watermarkText.isEmpty && settings.watermarkImage == nil {
            let out = unique(folder.appending(path: fileName(settings, base: originalName, props: props, seq: sequence) + "." + source.pathExtension))
            try FileManager.default.copyItem(at: source, to: out)
            return out
        }
        guard var image = try? engine.base(source, recipe: EditRecipe()) else { throw RenderEngine.RenderError.unreadable }
        if let edge = settings.longEdge, max(image.extent.width, image.extent.height) > CGFloat(edge) {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(CGFloat(edge) / max(image.extent.width, image.extent.height))
            image = filter.outputImage ?? image
        }
        image = watermark(image, settings)
        let (type, ext): (UTType, String) = switch settings.format {
        case .jpeg, .original: (.jpeg, "jpg")
        case .heic: (.heic, "heic")
        case .png: (.png, "png")
        case .tiff: (.tiff, "tif")
        }
        let space: CGColorSpace = switch settings.colorSpace {
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        case .proPhoto: CGColorSpace(name: CGColorSpace.rommrgb)!
        }
        let sixteen = settings.sixteenBit && (type == .png || type == .tiff)
        guard let cg = engine.context.createCGImage(image, from: image.extent, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: space) else {
            throw RenderEngine.RenderError.renderFailed
        }
        let out = unique(folder.appending(path: fileName(settings, base: originalName, props: props, seq: sequence) + "." + ext))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { throw RenderEngine.RenderError.writeFailed }
        var meta: [CFString: Any] = [:]
        switch settings.metadata {
        case .all: meta = props
        case .noLocation: meta = props; meta.removeValue(forKey: kCGImagePropertyGPSDictionary)
        case .none: meta = [:]
        }
        meta.removeValue(forKey: kCGImagePropertyMakerAppleDictionary)
        meta.removeValue(forKey: kCGImagePropertyDNGDictionary)
        meta[kCGImagePropertyOrientation] = 1
        meta[kCGImagePropertyPixelWidth] = cg.width
        meta[kCGImagePropertyPixelHeight] = cg.height
        if !settings.copyright.isEmpty {
            var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCopyright] = settings.copyright
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var tiff = meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; meta[kCGImagePropertyTIFFDictionary] = tiff }
        if type == .jpeg || type == .heic { meta[kCGImageDestinationLossyCompressionQuality] = settings.quality }
        CGImageDestinationAddImage(dest, cg, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderEngine.RenderError.writeFailed }
        return out
    }

    static func watermark(_ image: CIImage, _ s: ExportSettings) -> CIImage {
        let e = image.extent
        let longEdge = max(e.width, e.height)
        var mark: CIImage?
        if let path = s.watermarkImage, let img = CIImage(contentsOf: URL(fileURLWithPath: path)) {
            let target = longEdge * CGFloat(s.watermarkSize) / 100 * 2.5
            let scale = target / max(img.extent.width, img.extent.height)
            mark = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else if !s.watermarkText.isEmpty {
            let font = NSFont.systemFont(ofSize: longEdge * CGFloat(s.watermarkSize) / 100, weight: .medium)
            let text = NSAttributedString(string: s.watermarkText, attributes: [.font: font, .foregroundColor: NSColor.white,
                .shadow: { let sh = NSShadow(); sh.shadowBlurRadius = font.pointSize / 8; sh.shadowColor = .black.withAlphaComponent(0.5); return sh }()])
            let filter = CIFilter.attributedTextImageGenerator()
            filter.text = text
            filter.scaleFactor = 1
            mark = filter.outputImage
        }
        guard var m = mark else { return image }
        m = m.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.watermarkOpacity / 100))])
        let margin = longEdge * 0.02
        let w = m.extent.width, h = m.extent.height
        let origin: CGPoint = switch s.watermarkPosition {
        case .bottomRight: CGPoint(x: e.maxX - w - margin, y: e.minY + margin)
        case .bottomLeft: CGPoint(x: e.minX + margin, y: e.minY + margin)
        case .topRight: CGPoint(x: e.maxX - w - margin, y: e.maxY - h - margin)
        case .topLeft: CGPoint(x: e.minX + margin, y: e.maxY - h - margin)
        case .center: CGPoint(x: e.midX - w / 2, y: e.midY - h / 2)
        }
        m = m.transformed(by: CGAffineTransform(translationX: origin.x - m.extent.minX, y: origin.y - m.extent.minY))
        return m.composited(over: image).cropped(to: e)
    }

    public static func fileName(_ s: ExportSettings, base: String, props: [CFString: Any], seq: Int) -> String {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let date = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)?.prefix(10).replacingOccurrences(of: ":", with: "-") ?? ""
        let camera = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? ""
        var name = s.naming.isEmpty ? "{name}" : s.naming
        name = name.replacingOccurrences(of: "{name}", with: base)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{seq}", with: String(format: "%04d", seq))
            .replacingOccurrences(of: "{camera}", with: camera)
        return name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
    }

    static func unique(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}
