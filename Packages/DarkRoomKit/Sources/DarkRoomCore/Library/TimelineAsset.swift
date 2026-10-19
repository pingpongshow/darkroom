import Foundation
import ImmichAPI

/// Lightweight asset record for grids and timelines (decoded from Immich's columnar time buckets).
public struct TimelineAsset: Identifiable, Hashable, Sendable {
    public var id: String
    public var isImage: Bool
    /// Width / height of the displayed (possibly edited) rendition.
    public var ratio: Double
    public var thumbhash: String?
    public var fileCreatedAt: Date
    public var localOffsetHours: Double
    public var isFavorite: Bool
    public var isTrashed: Bool
    public var livePhotoVideoID: String?
    /// Video duration in seconds (nil for photos).
    public var duration: Double?
    public var ownerID: String
    public var visibility: AssetVisibility
    public var projectionType: String?
    public var stackID: String?
    public var stackCount: Int?
    public var city: String?
    public var country: String?
    public var latitude: Double?
    public var longitude: Double?

    public var isVideo: Bool { !isImage }
    public var isLivePhoto: Bool { livePhotoVideoID != nil }
    public var isPanorama: Bool { projectionType == "EQUIRECTANGULAR" }
    /// Cache key that changes whenever Immich re-renders the asset (e.g. after an edit).
    public var cacheKey: String { thumbhash ?? id }

    /// Local wall-clock date at capture (Immich's localOffsetHours applied).
    public var localDate: Date { fileCreatedAt.addingTimeInterval(localOffsetHours * 3600) }

    public init(id: String, isImage: Bool, ratio: Double, thumbhash: String?, fileCreatedAt: Date,
                localOffsetHours: Double = 0, isFavorite: Bool = false, isTrashed: Bool = false,
                livePhotoVideoID: String? = nil, duration: Double? = nil, ownerID: String,
                visibility: AssetVisibility = .timeline, projectionType: String? = nil, stackID: String? = nil,
                stackCount: Int? = nil, city: String? = nil, country: String? = nil,
                latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id; self.isImage = isImage; self.ratio = ratio; self.thumbhash = thumbhash
        self.fileCreatedAt = fileCreatedAt; self.localOffsetHours = localOffsetHours; self.isFavorite = isFavorite
        self.isTrashed = isTrashed; self.livePhotoVideoID = livePhotoVideoID; self.duration = duration
        self.ownerID = ownerID; self.visibility = visibility; self.projectionType = projectionType
        self.stackID = stackID; self.stackCount = stackCount; self.city = city; self.country = country
        self.latitude = latitude; self.longitude = longitude
    }

    /// Unpacks Immich's column-oriented bucket response.
    public static func decode(_ dto: TimeBucketAssetResponseDto) -> [TimelineAsset] {
        dto.id.indices.map { i in
            let stack = dto.stack?[safe: i] ?? nil
            return TimelineAsset(
                id: dto.id[i],
                isImage: dto.isImage[safe: i] ?? true,
                ratio: dto.ratio[safe: i].map { $0 > 0 ? $0 : 1 } ?? 1,
                thumbhash: dto.thumbhash[safe: i] ?? nil,
                fileCreatedAt: ImmichDate.parse(dto.fileCreatedAt[safe: i] ?? "") ?? .distantPast,
                localOffsetHours: dto.localOffsetHours[safe: i] ?? 0,
                isFavorite: dto.isFavorite[safe: i] ?? false,
                isTrashed: dto.isTrashed[safe: i] ?? false,
                livePhotoVideoID: dto.livePhotoVideoId[safe: i] ?? nil,
                duration: (dto.duration[safe: i] ?? nil).map { Double($0) / 1000 },
                ownerID: dto.ownerId[safe: i] ?? "",
                visibility: dto.visibility[safe: i] ?? .timeline,
                projectionType: dto.projectionType[safe: i] ?? nil,
                stackID: stack?.first,
                stackCount: stack.flatMap { $0.count > 1 ? Int($0[1]) : nil },
                city: dto.city?[safe: i] ?? nil,
                country: dto.country?[safe: i] ?? nil,
                latitude: dto.latitude?[safe: i] ?? nil,
                longitude: dto.longitude?[safe: i] ?? nil)
        }
    }
}

public extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Immich timestamps: ISO 8601, usually with fractional seconds.
public enum ImmichDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    public static func parse(_ text: String) -> Date? {
        lock.withLock { fractional.date(from: text) ?? plain.date(from: text) }
    }

    public static func format(_ date: Date) -> String {
        lock.withLock { fractional.string(from: date) }
    }
}

public extension TimelineAsset {
    /// Builds a grid record from a full asset response (search results, explore, map).
    init(_ dto: AssetResponseDto) {
        let w = Double(dto.width ?? dto.exifInfo?.exifImageWidth ?? 1)
        let h = Double(dto.height ?? dto.exifInfo?.exifImageHeight ?? 1)
        let created = ImmichDate.parse(dto.fileCreatedAt) ?? .distantPast
        let local = ImmichDate.parse(dto.localDateTime) ?? created
        self.init(id: dto.id, isImage: dto.type != .video, ratio: h > 0 ? max(w / h, 0.05) : 1,
                  thumbhash: dto.thumbhash, fileCreatedAt: created,
                  localOffsetHours: (local.timeIntervalSince(created) / 3600).rounded(),
                  isFavorite: dto.isFavorite, isTrashed: dto.isTrashed, livePhotoVideoID: dto.livePhotoVideoId,
                  duration: dto.duration.map { Double($0) / 1000 }, ownerID: dto.ownerId, visibility: dto.visibility,
                  projectionType: dto.exifInfo?.projectionType, stackID: dto.stack?.id,
                  stackCount: dto.stack?.assetCount, city: dto.exifInfo?.city, country: dto.exifInfo?.country,
                  latitude: dto.exifInfo?.latitude, longitude: dto.exifInfo?.longitude)
    }
}
