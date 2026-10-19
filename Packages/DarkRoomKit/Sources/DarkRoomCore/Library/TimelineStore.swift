import Foundation
import ImmichAPI

/// Which assets a timeline shows. One store type serves Photos, albums, people, favourites,
/// archive, trash, tags and partners.
public struct TimelineQuery: Hashable, Sendable {
    public var visibility: AssetVisibility?
    public var isFavorite: Bool?
    public var isTrashed: Bool?
    public var albumID: String?
    public var personID: String?
    public var tagID: String?
    public var userID: String?
    public var withPartners: Bool?
    public var withStacked: Bool
    public var withCoordinates: Bool
    public var newestFirst: Bool

    public init(visibility: AssetVisibility? = nil, isFavorite: Bool? = nil, isTrashed: Bool? = nil,
                albumID: String? = nil, personID: String? = nil, tagID: String? = nil, userID: String? = nil,
                withPartners: Bool? = nil, withStacked: Bool = true, withCoordinates: Bool = false,
                newestFirst: Bool = true) {
        self.visibility = visibility; self.isFavorite = isFavorite; self.isTrashed = isTrashed
        self.albumID = albumID; self.personID = personID; self.tagID = tagID; self.userID = userID
        self.withPartners = withPartners; self.withStacked = withStacked; self.withCoordinates = withCoordinates
        self.newestFirst = newestFirst
    }

    public static let photos = TimelineQuery(visibility: .timeline, withPartners: true, withStacked: true)
    public static let favorites = TimelineQuery(visibility: .timeline, isFavorite: true, withStacked: true)
    public static let archive = TimelineQuery(visibility: .archive, withStacked: true)
    public static let trash = TimelineQuery(isTrashed: true, withStacked: false)
    public static func album(_ id: String) -> TimelineQuery { TimelineQuery(albumID: id, withStacked: false) }
    public static func person(_ id: String) -> TimelineQuery { TimelineQuery(visibility: .timeline, personID: id, withStacked: false) }
    public static func tag(_ id: String) -> TimelineQuery { TimelineQuery(tagID: id, withStacked: false) }
    public static func partner(_ userID: String) -> TimelineQuery { TimelineQuery(visibility: .timeline, userID: userID, withStacked: true) }
}

/// One month section of a timeline. Assets are loaded on demand.
public struct TimelineSection: Identifiable, Hashable, Sendable {
    public var id: String { bucket }
    /// Immich bucket key, e.g. "2026-10-01".
    public var bucket: String
    public var count: Int
    public var date: Date
    public var assets: [TimelineAsset]?
    public var isLoaded: Bool { assets != nil }
    /// Overrides the month title (e.g. "Best matches" for relevance-ordered search results).
    public var customTitle: String?

    public var title: String {
        customTitle ?? date.formatted(.dateTime.month(.wide).year())
    }
}

/// Loads and keeps a timeline: section list up front, assets per month on demand.
@MainActor
public final class TimelineStore: ObservableObject {
    public let client: ImmichClient
    public private(set) var query: TimelineQuery
    @Published public private(set) var sections: [TimelineSection] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    /// Bumped whenever asset contents change (for views that cache layouts).
    @Published public private(set) var revision = 0
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// For result sets that aren't Immich timelines (search, map selections): returns every asset.
    private let provider: (@Sendable () async throws -> [TimelineAsset])?
    private var groupByMonth = true
    private var flatTitle = ""

    public init(client: ImmichClient, query: TimelineQuery) {
        self.client = client
        self.query = query
        self.provider = nil
    }

    /// A store showing a fixed result set, grouped into months by local capture date.
    /// With `groupByMonth: false` the results stay in the provider's order (relevance) in one section.
    public init(client: ImmichClient, groupByMonth: Bool = true, flatTitle: String = "Results",
                provider: @escaping @Sendable () async throws -> [TimelineAsset]) {
        self.client = client
        self.query = TimelineQuery()
        self.provider = provider
        self.groupByMonth = groupByMonth
        self.flatTitle = flatTitle
    }

    public var isStatic: Bool { provider != nil }

    /// Groups a flat, already ordered asset list into month sections.
    public static func monthSections(_ assets: [TimelineAsset]) -> [TimelineSection] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var sections: [TimelineSection] = []
        for asset in assets {
            let parts = calendar.dateComponents([.year, .month], from: asset.localDate)
            let bucket = String(format: "%04d-%02d-01", parts.year ?? 1970, parts.month ?? 1)
            if sections.last?.bucket == bucket {
                sections[sections.count - 1].assets!.append(asset)
                sections[sections.count - 1].count += 1
            } else if let index = sections.firstIndex(where: { $0.bucket == bucket }) {
                sections[index].assets!.append(asset)
                sections[index].count += 1
            } else {
                sections.append(TimelineSection(bucket: bucket, count: 1, date: bucketDate(bucket), assets: [asset]))
            }
        }
        return sections
    }

    public var totalCount: Int { sections.reduce(0) { $0 + $1.count } }

    /// Fetches the month list. Previously loaded months are kept if their counts didn't change.
    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        if let provider {
            do {
                let assets = try await provider()
                if groupByMonth {
                    sections = Self.monthSections(assets)
                } else {
                    sections = assets.isEmpty ? [] : [TimelineSection(bucket: "results", count: assets.count, date: .distantPast,
                                                                      assets: assets, customTitle: flatTitle)]
                }
                error = nil
                revision += 1
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        do {
            let buckets = try await client.getTimeBuckets(
                albumId: query.albumID, isFavorite: query.isFavorite, isTrashed: query.isTrashed,
                order: query.newestFirst ? .desc : .asc, personId: query.personID, tagId: query.tagID,
                userId: query.userID, visibility: query.visibility, withCoordinates: query.withCoordinates,
                withPartners: query.withPartners, withStacked: query.withStacked)
            let previous = Dictionary(uniqueKeysWithValues: sections.map { ($0.bucket, $0) })
            sections = buckets.map { bucket in
                var section = TimelineSection(bucket: bucket.timeBucket, count: bucket.count,
                                              date: Self.bucketDate(bucket.timeBucket), assets: nil)
                if let old = previous[bucket.timeBucket], old.count == bucket.count { section.assets = old.assets }
                return section
            }
            error = nil
            revision += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Ensures a month's assets are loaded (deduplicates concurrent requests).
    public func loadSection(_ bucket: String) async {
        guard provider == nil else { return }
        if let index = sections.firstIndex(where: { $0.bucket == bucket }), sections[index].isLoaded { return }
        if let task = inFlight[bucket] { await task.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let dto = try await self.client.getTimeBucket(
                    albumId: query.albumID, isFavorite: query.isFavorite, isTrashed: query.isTrashed,
                    order: query.newestFirst ? .desc : .asc, personId: query.personID, tagId: query.tagID,
                    timeBucket: bucket, userId: query.userID, visibility: query.visibility,
                    withCoordinates: query.withCoordinates, withPartners: query.withPartners,
                    withStacked: query.withStacked)
                let assets = TimelineAsset.decode(dto)
                if let index = self.sections.firstIndex(where: { $0.bucket == bucket }) {
                    self.sections[index].assets = assets
                    self.sections[index].count = assets.count
                    self.revision += 1
                }
            } catch {
                self.error = error.localizedDescription
            }
            self.inFlight[bucket] = nil
        }
        inFlight[bucket] = task
        await task.value
    }

    /// Loads every month (used by "select all", export, etc.).
    public func loadAll() async {
        for section in sections where !section.isLoaded { await loadSection(section.bucket) }
    }

    /// Asset ids in display order across loaded sections.
    public var loadedAssets: [TimelineAsset] { sections.compactMap(\.assets).flatMap { $0 } }

    public func asset(_ id: String) -> TimelineAsset? {
        for section in sections { if let a = section.assets?.first(where: { $0.id == id }) { return a } }
        return nil
    }

    /// Re-fetches only the months that contain (or may contain) the given assets.
    public func refresh(assetIDs: Set<String>) async {
        let touched = sections.filter { $0.assets?.contains { assetIDs.contains($0.id) } ?? false }.map(\.bucket)
        await reload()
        for bucket in touched {
            if let index = sections.firstIndex(where: { $0.bucket == bucket }) { sections[index].assets = nil }
            await loadSection(bucket)
        }
    }

    /// Applies a local change optimistically (e.g. favourite toggled) without a round-trip.
    public func update(_ id: String, _ change: (inout TimelineAsset) -> Void) {
        for s in sections.indices {
            guard let a = sections[s].assets?.firstIndex(where: { $0.id == id }) else { continue }
            change(&sections[s].assets![a])
            revision += 1
            return
        }
    }

    /// Removes assets locally (after trash/delete/archive), keeping counts consistent.
    public func remove(_ ids: Set<String>) {
        for s in sections.indices {
            guard let assets = sections[s].assets else { continue }
            let kept = assets.filter { !ids.contains($0.id) }
            if kept.count != assets.count {
                sections[s].assets = kept
                sections[s].count = kept.count
            }
        }
        sections.removeAll { $0.count == 0 }
        revision += 1
    }

    static func bucketDate(_ bucket: String) -> Date {
        let parts = bucket.prefix(10).split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts[safe: 0]
        components.month = parts[safe: 1]
        components.day = parts[safe: 2] ?? 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components) ?? .distantPast
    }
}
