import SwiftUI
import MapKit
import Accelerate
import ImmichAPI
import DarkRoomCore

/// RGB + luminance histogram (256 bins per channel), computed with vImage.
struct Histogram: Equatable {
    var red: [Float], green: [Float], blue: [Float], luma: [Float]
    var clippedShadows: Bool, clippedHighlights: Bool

    static func compute(_ image: CGImage) -> Histogram? {
        // Downsample for speed; histogram shape is unaffected.
        let maxSide = 512
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        var buffer = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        var r = [vImagePixelCount](repeating: 0, count: 256), g = r, b = r, a = r
        r.withUnsafeMutableBufferPointer { rp in g.withUnsafeMutableBufferPointer { gp in
            b.withUnsafeMutableBufferPointer { bp in a.withUnsafeMutableBufferPointer { ap in
                var pointers: [UnsafeMutablePointer<vImagePixelCount>?] = [rp.baseAddress, gp.baseAddress, bp.baseAddress, ap.baseAddress]
                _ = vImageHistogramCalculation_ARGB8888(&buffer, &pointers, vImage_Flags(kvImageNoFlags))
            } }
        } }
        // Luminance from the RGB bins (Rec. 709 weights applied to bin positions is not exact; use per-pixel).
        var lumaBins = [Float](repeating: 0, count: 256)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let y = 0.2126 * Float(pixels[i]) + 0.7152 * Float(pixels[i + 1]) + 0.0722 * Float(pixels[i + 2])
            lumaBins[min(255, Int(y))] += 1
        }
        func normalize(_ bins: [Float]) -> [Float] {
            let peak = bins.dropFirst().dropLast().max() ?? 1
            return bins.map { min(1, $0 / max(peak, 1)) }
        }
        let total = Float(w * h)
        return Histogram(red: normalize(r.map(Float.init)), green: normalize(g.map(Float.init)),
                         blue: normalize(b.map(Float.init)), luma: normalize(lumaBins),
                         clippedShadows: lumaBins[0] / total > 0.01, clippedHighlights: lumaBins[255] / total > 0.01)
    }
}

struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { context, size in
            func path(_ bins: [Float]) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    p.addLine(to: CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            context.blendMode = .screen
            context.fill(path(histogram.red), with: .color(.red.opacity(0.55)))
            context.fill(path(histogram.green), with: .color(.green.opacity(0.55)))
            context.fill(path(histogram.blue), with: .color(.blue.opacity(0.55)))
            context.blendMode = .normal
            context.stroke(path(histogram.luma), with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) { clipMarker(histogram.clippedShadows) }
        .overlay(alignment: .topTrailing) { clipMarker(histogram.clippedHighlights) }
        .accessibilityIdentifier("histogram")
    }

    private func clipMarker(_ on: Bool) -> some View {
        Image(systemName: "triangle.fill").font(.system(size: 7)).rotationEffect(.degrees(180))
            .foregroundStyle(on ? Color.white : Color.white.opacity(0.15)).padding(3)
    }
}

/// Loads full asset details (EXIF, people…) for the focused asset.
@MainActor
final class AssetDetailsModel: ObservableObject {
    @Published var asset: AssetResponseDto?
    @Published var albums: [AlbumResponseDto] = []
    private var loadedID: String?

    func load(_ id: String?, client: ImmichClient, force: Bool = false) async {
        guard let id else { asset = nil; return }
        guard force || id != loadedID else { return }
        loadedID = id
        asset = try? await client.getAssetInfo(id: id)
        albums = (try? await client.getAllAlbums(assetId: id)) ?? []
    }
}

/// EXIF summary + histogram overlay on the loupe (toggle with I).
struct InfoOverlay: View {
    @EnvironmentObject var library: LibraryModel
    let asset: TimelineAsset
    let image: CGImage
    @StateObject private var details = AssetDetailsModel()
    @State private var histogram: Histogram?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let histogram { HistogramView(histogram: histogram).frame(width: 220, height: 80) }
            if let exif = details.asset?.exifInfo {
                Text(ExifText.camera(exif)).font(.caption.weight(.semibold))
                Text(ExifText.exposure(exif)).font(.caption.monospacedDigit())
            }
            Text(details.asset?.originalFileName ?? "").font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info-overlay")
        .task(id: asset.id) {
            await details.load(asset.id, client: library.client)
        }
        .task(id: ObjectIdentifier(image)) {
            let cg = image
            histogram = await Task.detached(priority: .userInitiated) { Histogram.compute(cg) }.value
        }
    }
}

enum ExifText {
    static func camera(_ e: ExifResponseDto) -> String {
        [e.make, e.model].compactMap { $0 }.joined(separator: " ").replacingOccurrences(of: "Canon Canon", with: "Canon")
            + (e.lensModel.map { " · \($0)" } ?? "")
    }

    static func exposure(_ e: ExifResponseDto) -> String {
        var parts: [String] = []
        if let f = e.focalLength { parts.append("\(Int(f.rounded())) mm") }
        if let n = e.fNumber { parts.append(String(format: "ƒ/%.1f", n)) }
        if let t = e.exposureTime { parts.append("\(t) s") }
        if let iso = e.iso { parts.append("ISO \(iso)") }
        return parts.joined(separator: "   ")
    }

    static func megapixels(_ e: ExifResponseDto) -> String? {
        guard let w = e.exifImageWidth, let h = e.exifImageHeight else { return nil }
        return String(format: "%d × %d (%.1f MP)", w, h, Double(w * h) / 1_000_000)
    }

    static func fileSize(_ e: ExifResponseDto) -> String? {
        e.fileSizeInByte.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

/// Right-hand info panel (Lightroom's Metadata panel).
struct InfoPanel: View {
    @EnvironmentObject var library: LibraryModel
    @StateObject private var details = AssetDetailsModel()
    @State private var histogram: Histogram?
    @State private var descriptionDraft = ""
    @FocusState private var editingDescription: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Histogram") {
                    if let histogram { HistogramView(histogram: histogram).frame(height: 90) }
                    else { Rectangle().fill(Theme.panelRaised).frame(height: 90) }
                }
                if let asset = details.asset {
                    section("File") {
                        row("Name", asset.originalFileName)
                        row("Date", ImmichDate.parse(asset.localDateTime).map {
                            $0.formatted(Date.FormatStyle(date: .long, time: .shortened, timeZone: TimeZone(identifier: "UTC")!)) } ?? "")
                        if let e = asset.exifInfo {
                            if let mp = ExifText.megapixels(e) { row("Size", mp) }
                            if let fs = ExifText.fileSize(e) { row("File size", fs) }
                        }
                        row("Type", asset.livePhotoVideoId != nil ? "Live Photo" : asset.type.rawValue.capitalized)
                        HStack(spacing: 12) {
                            Button { library.toggleFavorite() } label: {
                                Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                                    .foregroundStyle(asset.isFavorite ? Color.pink : Theme.textSecondary)
                            }
                            .buttonStyle(.borderless).help("Favorite (H)").accessibilityIdentifier("info-favorite")
                            Button("Date…") { library.sheet = .dateTime(library.targetIDs) }.buttonStyle(.link)
                                .accessibilityIdentifier("info-edit-date")
                            Button("Location…") { library.sheet = .geotag(library.targetIDs) }.buttonStyle(.link)
                        }
                        .padding(.top, 2)
                    }
                    if let e = asset.exifInfo, e.make != nil || e.model != nil {
                        section("Camera") {
                            row("Camera", [e.make, e.model].compactMap { $0 }.joined(separator: " "))
                            if let lens = e.lensModel { row("Lens", lens) }
                            row("Exposure", ExifText.exposure(e))
                        }
                    }
                    if let e = asset.exifInfo, let lat = e.latitude, let lon = e.longitude {
                        section("Location") {
                            row("Place", [e.city, e.state, e.country].compactMap { $0 }.joined(separator: ", "))
                            Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                                                            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))) {
                                Marker("", coordinate: .init(latitude: lat, longitude: lon))
                            }
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .id(asset.id)
                        }
                    }
                    if let people = asset.people, !people.isEmpty {
                        section("People") {
                            Text(people.map { $0.name.isEmpty ? "Unnamed" : $0.name }.joined(separator: ", ")).foregroundStyle(Theme.text)
                        }
                    }
                    if !details.albums.isEmpty {
                        section("Albums") {
                            ForEach(details.albums, id: \.id) { Text($0.albumName).foregroundStyle(Theme.text) }
                        }
                    }
                    if let tags = asset.tags, !tags.isEmpty {
                        section("Tags") {
                            Text(tags.map(\.value).filter { !$0.hasPrefix("Culling/") }.joined(separator: ", ")).foregroundStyle(Theme.text)
                        }
                    }
                    section("Description") {
                        TextField("Add a description", text: $descriptionDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                            .focused($editingDescription)
                            .onSubmit(saveDescription)
                            .onChange(of: editingDescription) { _, editing in if !editing { saveDescription() } }
                            .accessibilityIdentifier("info-description")
                    }
                    section("Rating") {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                let rating = asset.exifInfo?.rating ?? 0
                                Button { library.setRating(star == rating ? 0 : star) } label: {
                                    Image(systemName: star <= rating ? "star.fill" : "star").foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("info-star-\(star)")
                            }
                        }
                        .help("Rate (0–5)")
                    }
                } else if library.focusedAssetID == nil {
                    Text("Select a photo to see its details.").foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(14)
            .font(.system(size: 12))
        }
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info-panel")
        .task(id: library.focusedAssetID) {
            await details.load(library.focusedAssetID, client: library.client)
            descriptionDraft = details.asset?.exifInfo?.description ?? ""
            await loadHistogram()
        }
        .task(id: library.detailsRevision) {
            guard library.detailsRevision > 0 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            await details.load(library.focusedAssetID, client: library.client, force: true)
            if !editingDescription { descriptionDraft = details.asset?.exifInfo?.description ?? "" }
        }
    }

    private func saveDescription() {
        guard let asset = details.asset, descriptionDraft != (asset.exifInfo?.description ?? "") else { return }
        let ids = [asset.id], text = descriptionDraft
        library.perform("Description", ids: ids, change: .metadata(ids: ids)) { try await $0.setDescription(ids, text) }
    }

    private func loadHistogram() async {
        histogram = nil
        guard let asset = library.focusedAsset, asset.isImage,
              let image = try? await library.pipeline.image(.init(assetID: asset.id, size: .preview, cacheKey: asset.cacheKey), maxPixel: 1024)
        else { return }
        histogram = await Task.detached(priority: .utility) { Histogram.compute(image) }.value
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).panelHeader()
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textSecondary).frame(width: 72, alignment: .leading)
            Text(value).foregroundStyle(Theme.text).textSelection(.enabled)
        }
    }
}
