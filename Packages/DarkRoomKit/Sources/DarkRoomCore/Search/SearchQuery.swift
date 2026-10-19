import Foundation
import ImmichAPI

/// A DarkRoom search: free text (Immich smart/CLIP search) plus optional metadata filters.
/// Without text it runs as an Immich metadata search.
public struct SearchQuery: Hashable, Sendable, Codable {
    public enum TextMode: String, Hashable, Sendable, Codable, CaseIterable {
        /// Natural language ("dog on a beach") via the machine-learning index.
        case smart
        /// File name contains.
        case fileName
        /// Description contains.
        case description
        /// Text recognised in the image (OCR).
        case ocr
    }

    public enum MediaType: String, Hashable, Sendable, Codable, CaseIterable { case all, photos, videos }

    public var text: String = ""
    public var textMode: TextMode = .smart
    public var personIDs: [String] = []
    public var tagIDs: [String] = []
    public var albumIDs: [String] = []
    public var country: String?
    public var state: String?
    public var city: String?
    public var make: String?
    public var model: String?
    public var lensModel: String?
    public var takenAfter: Date?
    public var takenBefore: Date?
    public var mediaType: MediaType = .all
    public var favoritesOnly = false
    public var minimumRating: Int?
    public var includeArchived = false
    public var notInAnyAlbum = false

    public init(text: String = "") { self.text = text }

    public var isEmpty: Bool { self == SearchQuery() }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var assetType: AssetTypeEnum? {
        switch mediaType { case .all: nil; case .photos: AssetTypeEnum.image; case .videos: AssetTypeEnum.video }
    }
    var visibility: AssetVisibility? { includeArchived ? nil : .timeline }

    public func smartDTO(page: Int, size: Int) -> SmartSearchDto {
        var dto = SmartSearchDto()
        dto.query = trimmedText
        dto.page = page; dto.size = size
        dto.personIds = personIDs.isEmpty ? nil : personIDs
        dto.tagIds = tagIDs.isEmpty ? nil : tagIDs
        dto.albumIds = albumIDs.isEmpty ? nil : albumIDs
        dto.country = country; dto.state = state; dto.city = city
        dto.make = make; dto.model = model; dto.lensModel = lensModel
        dto.takenAfter = takenAfter.map(ImmichDate.format); dto.takenBefore = takenBefore.map(ImmichDate.format)
        dto.type = assetType
        dto.isFavorite = favoritesOnly ? true : nil
        dto.rating = minimumRating
        dto.visibility = visibility
        dto.isNotInAlbum = notInAnyAlbum ? true : nil
        dto.withExif = true
        return dto
    }

    public func metadataDTO(page: Int, size: Int) -> MetadataSearchDto {
        var dto = MetadataSearchDto()
        dto.page = page; dto.size = size
        switch textMode {
        case .fileName: dto.originalFileName = trimmedText.isEmpty ? nil : trimmedText
        case .description: dto.description = trimmedText.isEmpty ? nil : trimmedText
        case .ocr: dto.ocr = trimmedText.isEmpty ? nil : trimmedText
        case .smart: break
        }
        dto.personIds = personIDs.isEmpty ? nil : personIDs
        dto.tagIds = tagIDs.isEmpty ? nil : tagIDs
        dto.albumIds = albumIDs.isEmpty ? nil : albumIDs
        dto.country = country; dto.state = state; dto.city = city
        dto.make = make; dto.model = model; dto.lensModel = lensModel
        dto.takenAfter = takenAfter.map(ImmichDate.format); dto.takenBefore = takenBefore.map(ImmichDate.format)
        dto.type = assetType
        dto.isFavorite = favoritesOnly ? true : nil
        dto.rating = minimumRating
        dto.visibility = visibility
        dto.isNotInAlbum = notInAnyAlbum ? true : nil
        dto.withExif = true
        dto.withStacked = true
        dto.order = .desc
        return dto
    }

    /// Whether this runs as a smart (CLIP) search rather than a metadata search.
    public var usesSmartSearch: Bool { textMode == .smart && !trimmedText.isEmpty }
}

public enum SearchService {
    /// Runs a search, following pages up to `limit` results. Smart results keep relevance order;
    /// metadata results are newest first.
    public static func run(_ query: SearchQuery, client: ImmichClient, limit: Int = 1000) async throws -> [AssetResponseDto] {
        var results: [AssetResponseDto] = []
        var page = 1
        let size = 250
        while results.count < limit {
            try Task.checkCancellation()
            let response = query.usesSmartSearch
                ? try await client.searchSmart(body: query.smartDTO(page: page, size: size))
                : try await client.searchAssets(body: query.metadataDTO(page: page, size: size))
            results += response.assets.items
            guard let next = response.assets.nextPage, let n = Int(next), n > page, !response.assets.items.isEmpty else { break }
            page = n
        }
        return Array(results.prefix(limit))
    }

    /// Assets for a grid. Smart search keeps relevance order within the flat list.
    public static func assets(_ query: SearchQuery, client: ImmichClient, limit: Int = 1000) async throws -> [TimelineAsset] {
        try await run(query, client: client, limit: limit).map(TimelineAsset.init)
    }
}

public extension SearchQuery {
    /// Short human description, e.g. "“beach” · Videos · Canon".
    var summary: String {
        var parts: [String] = []
        if !trimmedText.isEmpty {
            switch textMode {
            case .smart: parts.append("“\(trimmedText)”")
            case .fileName: parts.append("Name: \(trimmedText)")
            case .description: parts.append("Description: \(trimmedText)")
            case .ocr: parts.append("Text: \(trimmedText)")
            }
        }
        if let city { parts.append(city) } else if let state { parts.append(state) } else if let country { parts.append(country) }
        if let make { parts.append([make, model].compactMap { $0 }.joined(separator: " ")) }
        if let lensModel { parts.append(lensModel) }
        switch mediaType { case .all: break; case .photos: parts.append("Photos"); case .videos: parts.append("Videos") }
        if favoritesOnly { parts.append("Favorites") }
        if let minimumRating { parts.append(String(repeating: "★", count: minimumRating)) }
        if !personIDs.isEmpty { parts.append(personIDs.count == 1 ? "1 person" : "\(personIDs.count) people") }
        if takenAfter != nil || takenBefore != nil { parts.append("Date range") }
        if notInAnyAlbum { parts.append("Not in an album") }
        return parts.isEmpty ? "Search" : parts.joined(separator: " · ")
    }
}
