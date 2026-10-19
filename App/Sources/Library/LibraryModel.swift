import SwiftUI
import ImmichAPI
import DarkRoomCore

/// Library areas shown in the sidebar.
enum LibraryDestination: Hashable {
    case photos, explore, map, people, places, albums, sharing, favorites, recentlyAdded, recentlyEdited, memories
    case archive, locked, trash, tags, duplicates, bursts, largeFiles
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
        case .memories: "Memories"
        case .archive: "Archive"
        case .locked: "Locked Folder"
        case .trash: "Trash"
        case .tags: "Tags"
        case .duplicates: "Duplicates"
        case .bursts: "Bursts"
        case .largeFiles: "Large Files"
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
        case .recentlyAdded: "plus.square.on.square"
        case .recentlyEdited: "slider.horizontal.3"
        case .memories: "clock.arrow.circlepath"
        case .archive: "archivebox"
        case .locked: "lock"
        case .trash: "trash"
        case .tags, .tag: "tag"
        case .duplicates: "square.on.square"
        case .bursts: "square.stack.3d.forward.dottedline"
        case .largeFiles: "externaldrive"
        case .person: "person.crop.circle"
        case .search: "magnifyingglass"
        case .mapSelection: "map"
        }
    }

    /// Whether the destination shows a photo grid (timeline or a fixed result set).
    var showsGrid: Bool {
        switch self {
        case .search, .mapSelection, .recentlyAdded, .recentlyEdited, .largeFiles, .locked: true
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
        didSet {
            if blockedByUnsavedEdits(inEditor: mode == .develop, revert: {
                if !self.navigatingBack, !self.history.isEmpty { self.history.removeLast() }
                self.destination = oldValue
            }, retry: { [destination] in self.destination = destination }) { return }
            destinationChanged()
        }
    }
    @Published var timeline: TimelineStore
    @Published var mode: ViewMode = .grid {
        didSet {
            // Leaving the editor with unsaved changes always asks (Save / Don't Save / Keep Editing).
            if oldValue == .develop, mode != .develop {
                _ = blockedByUnsavedEdits(inEditor: true, revert: { self.mode = .develop }, retry: { [mode] in self.mode = mode })
            }
        }
    }
    /// Re-entrancy guard while a blocked change is being undone or retried.
    private var guardingEdits = false

    /// When the editor has unsaved changes, undoes a navigation that just happened and asks first; the change is
    /// re-applied after Save or Don't Save. Returns true when the change was blocked.
    private func blockedByUnsavedEdits(inEditor: Bool, revert: @escaping () -> Void, retry: @escaping @MainActor () -> Void) -> Bool {
        guard !guardingEdits, inEditor, let develop = developModel, develop.hasChanges else { return false }
        guardingEdits = true
        revert()
        guardingEdits = false
        if pendingDevelopLeave == nil { pendingDevelopLeave = PendingLeave(action: retry) }
        return true
    }

    /// Shown when leaving the editor with unsaved changes: Save, Don't Save or keep editing.
    @Published var pendingDevelopLeave: PendingLeave?

    struct PendingLeave: Identifiable {
        let id = UUID()
        let action: @MainActor () -> Void
        var onCancel: (@MainActor () -> Void)? = nil
    }

    /// For leaving that isn't a navigation (lock, switch user, sign out, quit): ask first when there are unsaved edits.
    func confirmLeavingEditor(then action: @escaping @MainActor () -> Void, onCancel: (@MainActor () -> Void)? = nil) {
        guard let develop = developModel, develop.hasChanges else { action(); return }
        pendingDevelopLeave = PendingLeave(action: action, onCancel: onCancel)
    }

    /// Runs `action` after the editor's unsaved changes are saved or discarded (asking first), or right away.
    func leaveDevelop(then action: @escaping @MainActor () -> Void) {
        guard mode == .develop, let develop = developModel, develop.hasChanges else { action(); return }
        if pendingDevelopLeave == nil { pendingDevelopLeave = PendingLeave(action: action) }
    }

    /// Editor Save: save to Immich, then back to the photo.
    func saveAndCloseEditor() {
        let develop = self.develop
        Task {
            NSApp.keyWindow?.makeFirstResponder(nil)
            await develop.save()
            if develop.error == nil { mode = .loupe }
        }
    }

    /// Editor Cancel: discard unsaved changes and go back to the photo.
    func cancelEditor() {
        develop.discardChanges()
        mode = .loupe
    }
    /// The Develop module's state (created on first use).
    var develop: DevelopModel {
        if let developModel { return developModel }
        let model = DevelopModel(library: self)
        developModel = model
        return model
    }
    private(set) var developModel: DevelopModel?
    /// Writes metadata changes into the files (original + Mac version).
    lazy var rewrites = FileRewriteQueue(library: self)
    /// "Edit in…" companion-app sessions.
    lazy var editIn = EditInModel(library: self)
    /// Import (file picker, drops, cards, watched folders).
    lazy var importer = ImportModel(library: self)
    @Published var selection: Set<String> = []
    @Published var focusedAssetID: String? {
        didSet {
            // Another photo picked while editing (filmstrip, arrows…): ask about unsaved changes first.
            if oldValue != focusedAssetID, mode == .develop {
                _ = blockedByUnsavedEdits(inEditor: true, revert: { self.focusedAssetID = oldValue }, retry: { [focusedAssetID] in self.focusedAssetID = focusedAssetID })
            }
        }
    }
    @Published var showLeftPanel = true
    @Published var showRightPanel = true
    @Published var showFilmstrip = true
    @Published var showInfoOverlay = false
    @Published var playingLive = false
    /// Where the loupe is drawn (window coordinates, top-left origin).
    var loupeFrame: CGRect = .zero
    var pendingLivePlay: String?
    /// Sideways swipe tracking over videos in the loupe.
    var videoSwipe = SwipeGesture()
    @AppStorage("gridCellSize", store: .darkRoom) var gridCellSize: Double = 180
    @Published var scrollRequest: String?
    /// Grid scroll position (per timeline store), restored when coming back from the loupe or Develop.
    var gridScroll: (store: ObjectIdentifier, y: CGFloat)?
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
    /// Culling: move to the next photo after rating or flagging.
    @Published var autoAdvance = UserDefaults.darkRoom.bool(forKey: "autoAdvance") {
        didSet { UserDefaults.darkRoom.set(autoAdvance, forKey: "autoAdvance") }
    }
    @Published var showFilterBar = false
    /// Read-only mode (Preferences ▸ Accounts): the client refuses every change to Immich.
    @Published var readOnly = false {
        didSet {
            client.writes.isReadOnly = readOnly
            AppState.setReadOnly(readOnly, for: session.account.id)
        }
    }
    @Published var confirmTrashRejects = false
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
        self.readOnly = session.client.writes.isReadOnly
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
        gridScroll = nil
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

    /// Back one level: Develop → photo → grid (the grid shows the photo you were on).
    func back() {
        switch mode {
        case .develop: leaveDevelop { [weak self] in self?.mode = .loupe }
        case .grid: break
        default:
            if let id = focusedAssetID { selection = [id] }
            mode = .grid
        }
    }

    func open(_ id: String) {
        focusedAssetID = id
        selection = [id]
        mode = .loupe
    }

    func step(_ delta: Int) {
        if mode == .develop, developModel?.hasChanges == true {
            leaveDevelop { [weak self] in self?.step(delta) }
            return
        }
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
        guard !client.writes.isReadOnly else { return }
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
