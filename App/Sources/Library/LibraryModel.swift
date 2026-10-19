import SwiftUI
import ImmichAPI
import DarkRoomCore

/// Library areas shown in the sidebar.
enum LibraryDestination: Hashable {
    case photos, explore, map, people, places, albums, sharing, favorites, recentlyAdded, recentlyEdited
    case archive, locked, trash, tags, folders, duplicates
    case album(String), person(String), tag(String), partner(String)

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

/// Grid (G) / loupe (E) / compare (C) / survey (N) / develop (D), as in Lightroom.
enum ViewMode: String {
    case grid, loupe, develop, compare, survey
}

/// Per-user library state: navigation, selection, view mode, image loading and live updates.
@MainActor
final class LibraryModel: ObservableObject {
    let session: UserSession
    let pipeline: ImagePipeline
    @Published var destination: LibraryDestination = .photos { didSet { destinationChanged() } }
    @Published var timeline: TimelineStore
    @Published var mode: ViewMode = .grid
    @Published var selection: Set<String> = []
    @Published var focusedAssetID: String?
    @Published var showLeftPanel = true
    @Published var showRightPanel = true
    @Published var showFilmstrip = true
    @Published var showInfoOverlay = false
    @Published var playingLive = false
    @AppStorage("gridCellSize") var gridCellSize: Double = 180
    @Published var scrollRequest: String?
    @Published var statusMessage: String?

    private var socket: ImmichSocket?
    private var socketTask: Task<Void, Never>?

    init(session: UserSession) {
        self.session = session
        self.pipeline = ImagePipeline(client: session.client, accountID: session.account.id)
        self.timeline = TimelineStore(client: session.client, query: .photos)
    }

    var client: ImmichClient { session.client }

    func start() async {
        await timeline.reload()
        loadRemainingInBackground(timeline)
        startLiveUpdates()
        Task.detached(priority: .background) { [pipeline] in await pipeline.trimDiskCache() }
    }

    func stop() {
        socket?.stop()
        socketTask?.cancel()
    }

    private func destinationChanged() {
        selection = []
        focusedAssetID = nil
        mode = .grid
        guard let query = destination.timelineQuery else { return }
        let store = TimelineStore(client: client, query: query)
        timeline = store
        Task {
            await store.reload()
            loadRemainingInBackground(store)
        }
    }

    /// Loads the remaining months a few at a time so the filmstrip, stepping and select-all cover
    /// the whole timeline (the grid still loads visible months first).
    private func loadRemainingInBackground(_ store: TimelineStore) {
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
            await timeline.reload()
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
