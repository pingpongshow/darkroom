import SwiftUI
import ImmichAPI
import DarkRoomCore

/// Library areas shown in the sidebar.
enum LibraryDestination: Hashable {
    case photos, explore, map, people, places, albums, sharing, favorites, recentlyAdded, recentlyEdited
    case archive, locked, trash, tags, folders, duplicates
    case album(String), person(String), tag(String), partner(String)
    case search(SearchQuery)
    case mapSelection(MapSelection)

    var title: String {
        switch self {
        case .photos: "Photos"
        case .explore: "Explore"
        case .map: "Map"
        case .people: "People"
        case .places: "Places"
        case .albums: "Albums"
        case .sharing: "Sharing"
        case .favorites: "Favorites"
        case .recentlyAdded: "Recently Added"
        case .recentlyEdited: "Recently Edited"
        case .archive: "Archive"
        case .locked: "Locked Folder"
        case .trash: "Trash"
        case .tags: "Tags"
        case .folders: "Folders"
        case .duplicates: "Duplicates"
        case .album: "Album"
        case .person: "Person"
        case .tag: "Tag"
        case .partner: "Partner"
        case .search: "Search"
        case .mapSelection(let selection): selection.title
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .explore: "sparkle.magnifyingglass"
        case .map: "map"
        case .people: "person.2"
        case .places: "mappin.and.ellipse"
        case .albums, .album: "rectangle.stack"
        case .sharing, .partner: "person.2.wave.2"
        case .favorites: "heart"
        case .recentlyAdded: "clock.arrow.circlepath"
        case .recentlyEdited: "slider.horizontal.3"
        case .archive: "archivebox"
        case .locked: "lock"
        case .trash: "trash"
        case .tags, .tag: "tag"
        case .folders: "folder"
        case .duplicates: "square.on.square"
        case .person: "person.crop.circle"
        case .search: "magnifyingglass"
        case .mapSelection: "map"
        }
    }

    /// Whether the destination shows a photo grid (timeline or a fixed result set).
    var showsGrid: Bool {
        switch self {
        case .search, .mapSelection: true
        default: timelineQuery != nil
        }
    }

    /// Timeline query for destinations that show a photo grid.
    var timelineQuery: TimelineQuery? {
        switch self {
        case .photos: .photos
        case .favorites: .favorites
        case .archive: .archive
        case .trash: .trash
        case .album(let id): .album(id)
        case .person(let id): .person(id)
        case .tag(let id): .tag(id)
        case .partner(let id): .partner(id)
        default: nil
        }
    }
}

/// Photos picked on the map (a cluster or the visible area).
struct MapSelection: Hashable {
    var title: String
    var assetIDs: [String]
}

/// Grid (G) / loupe (E) / compare (C) / survey (N) / develop (D), as in Lightroom.
enum ViewMode: String {
    case grid, loupe, develop, compare, survey
}

/// Per-user library state: navigation, selection, view mode, image loading and live updates.
@MainActor
final class LibraryModel: ObservableObject {
    let session: UserSession
    let pipeline: ImagePipeline
    @Published var destination: LibraryDestination = .photos {
        willSet { if !navigatingBack, newValue != destination { history.append(destination) } }
        didSet { destinationChanged() }
    }
    @Published var timeline: TimelineStore
    @Published var mode: ViewMode = .grid
    @Published var selection: Set<String> = []
    @Published var focusedAssetID: String?
    @Published var showLeftPanel = true
    @Published var showRightPanel = true
    @Published var showFilmstrip = true
    @Published var showInfoOverlay = false
    @Published var playingLive = false
    @AppStorage("gridCellSize", store: .darkRoom) var gridCellSize: Double = 180
    @Published var scrollRequest: String?
    @Published var statusMessage: String?
    /// Search being edited in the toolbar / filter popover.
    @Published var searchDraft = SearchQuery()
    /// Names for person destinations (filled by People / Explore).
    @Published var personNames: [String: String] = [:]
    /// Navigation history for Back (⌘[).
    private var history: [LibraryDestination] = []
    private var navigatingBack = false
    /// Every geotagged timeline asset, loaded on first use of the map.
    private var mapStore: TimelineStore?
    /// The window's undo manager (set by the shell) for ⌘Z of organising actions.
    weak var undoManager: UndoManager?
    /// Bumped when asset details change so the info panel reloads.
    @Published var detailsRevision = 0
    @Published var sheet: LibrarySheet?
    /// The user's albums (owned and shared), for Add to Album and the Albums view.
    @Published var albums: [AlbumResponseDto] = []
    @Published var copiedLocation: CLLocationCoordinate2DBox?
    var recentAlbumIDs: [String] {
        get { UserDefaults.darkRoom.stringArray(forKey: "recentAlbums-\(session.account.id)") ?? [] }
        set { UserDefaults.darkRoom.set(Array(newValue.prefix(10)), forKey: "recentAlbums-\(session.account.id)"); objectWillChange.send() }
    }

    private var socket: ImmichSocket?
    private var socketTask: Task<Void, Never>?

    init(session: UserSession) {
        self.session = session
        self.pipeline = ImagePipeline(client: session.client, accountID: session.account.id)
        self.timeline = TimelineStore(client: session.client, query: .photos)
    }

    var client: ImmichClient { session.client }

    func loadAlbums() async {
        if let all = try? await client.getAllAlbums() {
            albums = all.sorted { $0.albumName.localizedCaseInsensitiveCompare($1.albumName) == .orderedAscending }
        }
    }

    func start() async {
        Task { await loadAlbums() }
        await timeline.reload()
        loadRemainingInBackground(timeline)
        startLiveUpdates()
        Task.detached(priority: .background) { [pipeline] in await pipeline.trimDiskCache() }
    }

    func stop() {
        socket?.stop()
        socketTask?.cancel()
    }

    var title: String {
        switch destination {
        case .person(let id): personNames[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed person"
        case .search(let query): query.summary
        default: destination.title
        }
    }

    var canGoBack: Bool { !history.isEmpty }

    func goBack() {
        guard let previous = history.popLast() else { return }
        navigatingBack = true
        destination = previous
        navigatingBack = false
    }

    func search(_ query: SearchQuery) {
        searchDraft = query
        destination = query.isEmpty ? .photos : .search(query)
    }

    /// All geotagged photos (loads every month once; later calls reuse it).
    func geotaggedAssets() async -> [TimelineAsset] {
        let store: TimelineStore
        if let mapStore { store = mapStore } else {
            var query = TimelineQuery.photos
            query.withCoordinates = true
            store = TimelineStore(client: client, query: query)
            mapStore = store
            await store.reload()
        }
        await store.loadAll()
        return store.loadedAssets.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private func makeStore(for destination: LibraryDestination) -> TimelineStore? {
        switch destination {
        case .search(let query):
            let client = self.client
            return TimelineStore(client: client, groupByMonth: !query.usesSmartSearch, flatTitle: "Best matches") {
                try await SearchService.assets(query, client: client)
            }
        case .mapSelection(let selection):
            let ids = Set(selection.assetIDs)
            return TimelineStore(client: client) { [weak self] in
                guard let self else { return [] }
                return await self.geotaggedAssets().filter { ids.contains($0.id) }
            }
        default:
            return destination.timelineQuery.map { TimelineStore(client: client, query: $0) }
        }
    }

    private func destinationChanged() {
        selection = []
        focusedAssetID = nil
        mode = .grid
        if case .search(let query) = destination { searchDraft = query } else { searchDraft = SearchQuery() }
        guard let store = makeStore(for: destination) else { return }
        timeline = store
        Task {
            await store.reload()
            loadRemainingInBackground(store)
        }
    }

    /// Loads the remaining months a few at a time so the filmstrip, stepping and select-all cover
    /// the whole timeline (the grid still loads visible months first).
    private func loadRemainingInBackground(_ store: TimelineStore) {
        guard !store.isStatic else { return }
        Task { [weak self] in
            for section in store.sections where !section.isLoaded {
                guard let self, self.timeline === store, !Task.isCancelled else { return }
                await store.loadSection(section.bucket)
            }
        }
    }

    // MARK: Navigation within the current timeline

    var orderedAssets: [TimelineAsset] { timeline.loadedAssets }

    var focusedAsset: TimelineAsset? {
        guard let id = focusedAssetID else { return nil }
        return timeline.asset(id)
    }

    func open(_ id: String) {
        focusedAssetID = id
        selection = [id]
        mode = .loupe
    }

    func step(_ delta: Int) {
        let assets = orderedAssets
        guard !assets.isEmpty else { return }
        let index = focusedAssetID.flatMap { id in assets.firstIndex { $0.id == id } } ?? 0
        let next = min(max(index + delta, 0), assets.count - 1)
        focusedAssetID = assets[next].id
        selection = [assets[next].id]
        prefetchAround(next)
        // Load the next month when reaching the end of loaded assets.
        if next >= assets.count - 3, let unloaded = timeline.sections.first(where: { !$0.isLoaded }) {
            Task { await timeline.loadSection(unloaded.bucket) }
        }
    }

    func prefetchAround(_ index: Int) {
        let assets = orderedAssets
        let keys = (max(0, index - 2)...min(assets.count - 1, index + 3)).map {
            ImagePipeline.Key(assetID: assets[$0].id, size: .preview, cacheKey: assets[$0].cacheKey)
        }
        Task { await pipeline.prefetch(keys) }
    }

    func toggleMode(_ target: ViewMode) {
        if target == .loupe, focusedAssetID == nil {
            focusedAssetID = selection.first ?? orderedAssets.first?.id
        }
        mode = (mode == target && target != .grid) ? .grid : target
    }

    // MARK: Live updates (changes made in Immich web / phones appear immediately)

    private func startLiveUpdates() {
        let socket = ImmichSocket(client: client)
        self.socket = socket
        socketTask = Task { [weak self] in
            for await event in socket.events() {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: ImmichEvent) async {
        switch event {
        case .uploadSuccess, .assetRestore, .stackUpdate:
            if !timeline.isStatic { await timeline.reload() }
        case .albumUpdate:
            await loadAlbums()
        case .assetUpdate(let id), .assetEditReady(let id):
            await timeline.refresh(assetIDs: [id])
        case .assetTrash(let ids):
            if destination != .trash { timeline.remove(Set(ids)) } else { await timeline.reload() }
        case .assetDelete(let id), .assetHidden(let id):
            timeline.remove([id])
        case .sessionDelete:
            break
        default:
            break
        }
    }
}
