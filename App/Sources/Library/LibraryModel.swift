import SwiftUI
import ImmichAPI
import DarkRoomCore

/// Library areas shown in the sidebar.
enum LibraryDestination: Hashable {
    case photos, explore, map, people, places, albums, sharing, favorites, recentlyAdded, recentlyEdited
    case archive, locked, trash, tags, folders, duplicates, bursts, largeFiles
    case folder(String)
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
        case .bursts: "Bursts"
        case .largeFiles: "Large Files"
        case .folder(let path): (path as NSString).lastPathComponent
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
        case .bursts: "square.stack.3d.forward.dottedline"
        case .largeFiles: "externaldrive"
        case .folder: "folder"
        case .person: "person.crop.circle"
        case .search: "magnifyingglass"
        case .mapSelection: "map"
        }
    }

    /// Whether the destination shows a photo grid (timeline or a fixed result set).
    var showsGrid: Bool {
        switch self {
        case .search, .mapSelection, .recentlyAdded, .recentlyEdited, .largeFiles, .folder, .locked: true
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
        case .locked: TimelineQuery(visibility: .locked, withStacked: false)
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
    @Published var mode: ViewMode = .grid {
        didSet {
            // Leaving Develop saves the edit to Immich.
            if oldValue == .develop, mode != .develop, let develop = developModel { Task { await develop.save() } }
        }
    }
    /// The Develop module's state (created on first use).
    var develop: DevelopModel {
        if let developModel { return developModel }
        let model = DevelopModel(library: self)
        developModel = model
        return model
    }
    private var developModel: DevelopModel?
    /// Writes metadata changes into the files (original + Mac version).
    lazy var rewrites = FileRewriteQueue(library: self)
    /// "Edit in…" companion-app sessions.
    lazy var editIn = EditInModel(library: self)
    /// Import (file picker, drops, cards, watched folders).
    lazy var importer = ImportModel(library: self)
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
    @Published var partnerNames: [String: String] = [:]
    @Published var tagNames: [String: String] = [:]
    /// Album comments/likes panel in place of the info panel.
    @Published var showActivity = false
    /// The locked folder is unlocked (Immich PIN entered) for this visit.
    @Published var lockedUnlocked = false
    @Published var slideshow: SlideshowRequest?
    @Published var mergeRequest: MergeRequest?
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
        _ = importer   // resumes unfinished imports, starts watched folders and card detection
        await timeline.reload()
        loadRemainingInBackground(timeline)
        startLiveUpdates()
        Task.detached(priority: .background) { [pipeline] in await pipeline.trimDiskCache() }
        Task { await reconcile() }
    }

    func stop() {
        if lockedUnlocked { Task { [client] in try? await LibraryUtilities.lockLockedFolder(client) } }
        socket?.stop()
        socketTask?.cancel()
    }

    var title: String {
        switch destination {
        case .person(let id): personNames[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed person"
        case .search(let query): query.summary
        case .album(let id): albums.first { $0.id == id }?.albumName ?? "Album"
        case .tag(let id): tagNames[id] ?? "Tag"
        case .partner(let id): partnerNames[id].map { "\($0)’s Photos" } ?? "Partner"
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
        case .recentlyAdded:
            let client = self.client
            return TimelineStore(client: client, groupByMonth: false, flatTitle: "Uploaded in the last 30 days") {
                try await LibraryUtilities.recentlyAdded(client)
            }
        case .recentlyEdited:
            let client = self.client
            return TimelineStore(client: client, groupByMonth: false, flatTitle: "Edited in DarkRoom, newest first") {
                try await LibraryUtilities.recentlyEdited(client)
            }
        case .largeFiles:
            let client = self.client
            return TimelineStore(client: client, groupByMonth: false, flatTitle: "Largest first") {
                try await LibraryUtilities.largeFiles(client).map(TimelineAsset.init)
            }
        case .folder(let path):
            let client = self.client
            return TimelineStore(client: client) { try await LibraryUtilities.assets(inFolder: path, client: client) }
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

    /// Every timeline photo (for bursts); loaded once per session view.
    func allTimelineAssets() async -> [TimelineAsset] {
        let store = TimelineStore(client: client, query: .photos)
        await store.reload()
        await store.loadAll()
        return store.loadedAssets
    }

    private func destinationChanged() {
        selection = []
        focusedAssetID = nil
        mode = .grid
        showActivity = false
        if lockedUnlocked, destination != .locked {
            // Leaving the locked folder locks it again.
            lockedUnlocked = false
            Task { [client] in try? await LibraryUtilities.lockLockedFolder(client) }
        }
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
        if target == .develop {
            let id = focusedAssetID ?? selection.first ?? orderedAssets.first?.id
            if let id, timeline.asset(id)?.isVideo == true {
                flash("Videos can be rotated: Photo ▸ Rotate Left / Right (⌥⌘← / ⌥⌘→)")
                return
            }
        }
        if target == .loupe || target == .develop, focusedAssetID == nil {
            focusedAssetID = selection.first ?? orderedAssets.first?.id
        }
        mode = (mode == target && target != .grid) ? .grid : target
    }

    // MARK: Versions safety net

    func isRegisteredVersion(_ id: String) -> Bool { develop.versions.registry.all.contains { $0.versionID == id } }

    /// Un-hides originals whose version was removed elsewhere, re-hides originals something un-hid.
    func reconcile() async {
        let actions = await Reconciler(client: client, registry: develop.versions.registry).run()
        guard !actions.isEmpty else { return }
        let restored = actions.filter { if case .unhidOriginal = $0 { true } else { false } }.count
        if restored > 0 { flash("Restored \(restored) original\(restored == 1 ? "" : "s") whose edited version was removed in Immich") }
        await timeline.reload()
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
        case .assetTrash(let ids) where ids.contains(where: isRegisteredVersion):
            await reconcile()
            if destination != .trash { timeline.remove(Set(ids)) } else { await timeline.reload() }
        case .assetTrash(let ids):
            if destination != .trash { timeline.remove(Set(ids)) } else { await timeline.reload() }
        case .assetDelete(let id) where isRegisteredVersion(id):
            await reconcile()
        case .assetDelete(let id), .assetHidden(let id):
            timeline.remove([id])
        case .sessionDelete:
            break
        default:
            break
        }
    }
}
