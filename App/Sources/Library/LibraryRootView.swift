import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

/// The library window: sidebar · grid/loupe · info panel, Lightroom-style.
struct LibraryRootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var session: UserSession
    @StateObject private var holder = LibraryHolder()

    var body: some View {
        Group {
            if let library = holder.library {
                LibraryShell().environmentObject(library)
            } else {
                ProgressView()
            }
        }
        .task(id: session.id) {
            let library = LibraryModel(session: session)
            holder.library = library
            state.activeLibrary = library
            await library.start()
        }
        .onDisappear { holder.library?.stop() }
    }
}

@MainActor
final class LibraryHolder: ObservableObject {
    @Published var library: LibraryModel?
}

struct LibraryShell: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: LibraryModel
    @Environment(\.undoManager) private var undoManager
    @State private var keyMonitor: Any?
    @State private var confirmEmptyTrash = false
    @State private var trashCount = 0

    var body: some View {
        VStack(spacing: 0) {
            TopBar(timeline: library.timeline)
            Divider().overlay(Theme.separator)
            HStack(spacing: 0) {
                if library.showLeftPanel {
                    if library.mode == .develop {
                        PresetsPanel(develop: library.develop).frame(width: 220)
                    } else {
                        SidebarView().frame(width: 220)
                    }
                    Divider().overlay(Theme.separator)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if library.mode == .develop {
                    EmptyView()
                } else if library.showActivity, let album = library.currentAlbum {
                    Divider().overlay(Theme.separator)
                    ActivityPanel(album: album).frame(width: 280)
                } else if library.showRightPanel && library.destination.showsGrid {
                    Divider().overlay(Theme.separator)
                    InfoPanel().frame(width: 280)
                }
            }
            CardBanner(model: library.importer)
            ImportProgressBar(model: library.importer)
            EditSessionsBar(model: library.editIn)
            if let message = library.statusMessage {
                Text(message).font(.caption).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("status-message")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.panel)
            }
        }
        .background(Theme.background)
        .overlay {
            if let request = library.slideshow {
                SlideshowView(request: request).environmentObject(library)
            }
        }
        .focusedSceneObject(library)
        .sheet(item: $library.mergeRequest) { request in
            MergeSheet(request: request).environmentObject(library)
        }
        .sheet(item: $library.sheet) { sheet in
            LibrarySheetView(sheet: sheet).environmentObject(library)
        }
        .confirmationDialog("Move all rejected photos to Immich’s trash?", isPresented: $library.confirmTrashRejects) {
            Button("Move Rejects to Trash", role: .destructive) { library.trashRejects() }
        } message: { Text("They can be restored from the trash until Immich empties it.") }
        .onReceive(NotificationCenter.default.publisher(for: .openAlbumNamed)) { note in
            if let name = note.object as? String,
               let album = library.albums.first(where: { $0.albumName.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                library.destination = .album(album.id)
            }
        }
        .confirmationDialog("Permanently delete \(trashCount) item\(trashCount == 1 ? "" : "s")?", isPresented: $confirmEmptyTrash) {
            Button("Delete Permanently", role: .destructive) { library.emptyTrash() }
                .accessibilityIdentifier("confirm-empty-trash")
        } message: {
            Text("Everything in the trash is deleted from Immich for all devices. This can’t be undone.")
        }
        .onChange(of: library.sheet?.id) { _, id in
            if id == "emptyTrash", case .confirmEmptyTrash(let count) = library.sheet {
                library.sheet = nil
                trashCount = count
                confirmEmptyTrash = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPresetFiles)) { note in
            if let urls = note.object as? [URL] { library.importPresetFiles(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Preset / LUT files import as presets; photos, videos and folders open the import review.
            let presetExtensions: Set<String> = ["darkroom-preset", "xmp", "cube", "lrtemplate"]
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if presetExtensions.contains(url.pathExtension.lowercased()) { library.importPresetFiles([url]) }
                        else { library.importer.scan([url]) }
                    }
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importFiles)) { note in
            if let urls = note.object as? [URL] { library.importer.scan(urls) }
        }
        .onAppear { library.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in library.undoManager = manager }
        .onAppear {
            installKeyMonitor()
            if !UserDefaults.darkRoom.bool(forKey: "tourSeen"), ProcessInfo.processInfo.environment["DARKROOM_DATA_DIR"] == nil {
                library.sheet = .tour
            }
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    }

    @ViewBuilder private var content: some View {
        if library.destination == .locked && !library.lockedUnlocked {
            LockedFolderGate()
        } else if library.destination.showsGrid {
            switch library.mode {
            case .grid:
                VStack(spacing: 0) {
                    if library.showFilterBar { FilterBar() }
                    if library.destination == .trash { TrashBar(timeline: library.timeline) }
                    if let album = library.currentAlbum { AlbumHeader(album: album) }
                    if library.destination == .photos { MemoriesStrip() }
                    if case .folder(let path) = library.destination { FolderPathBar(path: path) }
                    ZStack(alignment: .trailing) {
                    GridView(timeline: library.timeline)
                    DateScrubber(timeline: library.timeline).frame(width: 64)
                }
                .overlay {
                    TimelineStatusOverlay(timeline: library.timeline, destination: library.destination)
                }
                }
            case .develop:
                DevelopView(develop: library.develop)
            case .compare:
                CompareView()
            case .survey:
                SurveyView()
            default:
                LoupeView()
                    .contextMenu { MenuEntriesView(entries: library.assetMenu(includeOpen: false)) }
            }
        } else {
            switch library.destination {
            case .explore: ExploreView()
            case .people: PeopleView()
            case .places: PlacesView()
            case .map: LibraryMapView()
            case .albums: AlbumsView()
            case .tags: TagsView()
            case .folders: FoldersView()
            case .duplicates: DuplicatesView()
            case .bursts: BurstsView()
            case .sharing: SharingView()
            default: ComingSoonView(destination: library.destination)
            }
        }
    }

    // MARK: Lightroom keyboard shortcuts

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Never steal keys from text fields.
            if let text = event.window?.firstResponder as? NSTextView, text.isEditable,
               !text.isFieldEditor || (text.delegate as? NSView)?.window != nil { return event }
            return handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        state.noteActivity()
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if library.mode == .develop, handleDevelop(event, mods: mods, key: key) { return true }
        if mods.contains(.command), event.keyCode == 36 { library.startSlideshow(); return true } // ⌘↩
        if mods == .control, let n = Int(key), (1...9).contains(n) { library.applyPresetShortcut(n); return true } // ⌃1…⌃9
        if mods.contains(.command) {
            switch key {
            case "=", "+": zoom(1.25); return true
            case "-": zoom(0.8); return true
            default: return false
            }
        }
        if event.keyCode == 48 { // Tab
            if mods.contains(.shift) {
                let show = !(library.showLeftPanel || library.showRightPanel || library.showFilmstrip)
                library.showLeftPanel = show; library.showRightPanel = show; library.showFilmstrip = show
            } else {
                let show = !(library.showLeftPanel || library.showRightPanel)
                library.showLeftPanel = show; library.showRightPanel = show
            }
            return true
        }
        guard mods.subtracting([.shift, .numericPad, .function]).isEmpty else { return false }
        if library.destination.showsGrid, !library.targetIDs.isEmpty, library.destination != .trash {
            switch key {
            case "p": library.setFlag(.pick); return true
            case "x": library.setFlag(.reject); return true
            case "u": library.setFlag(nil); return true
            case "c": library.toggleMode(.compare); return true
            case "n": library.toggleMode(.survey); return true
            case "h": library.toggleFavorite(); return true
            case "0", "1", "2", "3", "4", "5": library.setRating(Int(key)!); return true
            default: break
            }
            if event.keyCode == 51 || event.keyCode == 117 { library.trashSelection(); return true } // ⌫ / ⌦
        }
        switch event.keyCode {
        case 123 where library.mode != .grid: library.step(-1); return true  // ←
        case 124 where library.mode != .grid: library.step(1); return true   // →
        case 53 where library.mode != .grid: library.mode = .grid; return true // Esc
        default: break
        }
        switch key {
        case "g": library.mode = .grid; return true
        case "e": library.toggleMode(.loupe); return true
        case "d": library.toggleMode(.develop); return true
        case "\\" where library.mode == .grid: library.showFilterBar.toggle(); return true
        case "i": library.showInfoOverlay.toggle(); return true
        case "f": NSApp.keyWindow?.toggleFullScreen(nil); return true
        case " " where library.mode == .loupe:
            guard library.focusedAsset?.isLivePhoto == true else { return false }
            library.playingLive.toggle(); return true
        default: return false
        }
    }

    /// Lightroom Develop shortcuts.
    private func handleDevelop(_ event: NSEvent, mods: NSEvent.ModifierFlags, key: String) -> Bool {
        let develop = library.develop
        if mods == .command {
            switch key {
            case "z": develop.undo(); return true
            case "u": develop.autoTone(); return true
            default: return false
            }
        }
        if mods == [.command, .shift] {
            switch key {
            case "z": develop.redo(); return true
            case "u": develop.autoWhiteBalance(); return true
            case "c": develop.copySettings(); return true
            case "v": develop.pasteSettings(); return true
            default: return false
            }
        }
        guard mods.subtracting([.shift, .numericPad, .function]).isEmpty else { return false }
        if event.keyCode == 53 { // Esc
            if develop.cropping { develop.cropping = false }
            else if develop.eyedropper { develop.eyedropper = false }
            else if develop.tool != .none { develop.tool = .none }
            else { library.mode = .loupe }
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete
            if develop.tool == .spot, develop.selectedSpotID != nil { develop.deleteSelectedSpot(); return true }
            if develop.tool == .mask, develop.selectedMaskID != nil { develop.deleteSelectedMask(); return true }
            return true
        }
        if key == "m" {
            if mods.contains(.shift) { develop.addMask(.radial(center: [0.5, 0.5], radius: [0.25, 0.25], angle: 0, feather: 50, inside: true)) }
            else { develop.addMask(.linear(start: [0.5, 0.15], end: [0.5, 0.55])) }
            return true
        }
        switch key {
        case "k": develop.addMask(.brush(strokes: [])); return true
        case "q": develop.tool = develop.tool == .spot ? .none : .spot; return true
        case "o": develop.showMaskOverlay.toggle(); return true
        case "r": develop.cropping.toggle(); return true
        case "w": develop.eyedropper.toggle(); return true
        case "v": develop.set { $0.monochrome.toggle() }; return true
        case "\\": develop.showBefore.toggle(); return true
        case "d": return true
        default: return false
        }
    }

    private func zoom(_ factor: Double) {
        if library.mode == .grid {
            library.gridCellSize = min(480, max(90, library.gridCellSize * factor))
        } else if let scroll = NSApp.keyWindow?.contentView?.firstDescendant(of: ZoomScrollView.self) {
            scroll.zoom(by: factor)
        }
    }
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T { return match }
            if let match = sub.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var timeline: TimelineStore

    var body: some View {
        HStack(spacing: 14) {
            if library.canGoBack {
                Button { library.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("Back (⌘[)").accessibilityIdentifier("back")
            }
            Text(library.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                .lineLimit(1)
                .accessibilityIdentifier("destination-title")
            if library.destination.showsGrid {
                Text("\(timeline.totalCount) \(timeline.totalCount == 1 ? "item" : "items")").font(.caption).foregroundStyle(Theme.textTertiary)
                    .accessibilityIdentifier("item-count")
            }
            Spacer()
            SearchField()
            if library.destination.showsGrid {
                Picker("", selection: Binding(get: { library.mode == .develop ? ViewMode.develop : (library.mode == .grid ? .grid : .loupe) },
                                              set: { library.mode == $0 ? () : library.toggleMode($0) })) {
                    Image(systemName: "square.grid.3x3").tag(ViewMode.grid).help("Grid (G)")
                    Image(systemName: "rectangle").tag(ViewMode.loupe).help("Loupe (E)")
                    Image(systemName: "slider.horizontal.3").tag(ViewMode.develop).help("Develop (D)")
                }
                .pickerStyle(.segmented).frame(width: 130)
                .accessibilityIdentifier("mode-picker")
                if library.mode == .grid {
                    Slider(value: $library.gridCellSize, in: 90...480).frame(width: 110).help("Thumbnail size (⌘+ / ⌘−)")
                }
            }
            Button { library.importer.choose() } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(.borderless).help("Import (⇧⌘I)").accessibilityIdentifier("import-button")
            Button { library.showRightPanel.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless).help("Info panel (Tab)")
            Menu {
                Text(state.session?.account.email ?? "")
                Divider()
                Button("Lock DarkRoom") { state.lock() }
                Button("Switch User…") { state.lock() }
                if state.session?.account.isAdmin == true {
                    Button("Administration in Immich Web…") {
                        if let url = state.session?.client.serverURL.appending(path: "admin") { NSWorkspace.shared.open(url) }
                    }
                }
                Divider()
                Button("Sign Out") { Task { await state.signOutCurrent() } }
            } label: {
                if let account = state.session?.account { AvatarView(account: account, size: 24) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .accessibilityIdentifier("user-menu")
        }
        .padding(.horizontal, 14)
        .padding(.leading, 64) // room for the window buttons
        .frame(height: 44)
        .background(Theme.panel)
    }
}

struct SidebarView: View {
    @EnvironmentObject var library: LibraryModel

    private let sections: [(String, [LibraryDestination])] = [
        ("Library", [.photos, .explore, .map, .people, .places]),
        ("Collections", [.albums, .sharing, .favorites, .recentlyAdded, .recentlyEdited, .tags, .folders]),
        ("Manage", [.archive, .locked, .duplicates, .bursts, .largeFiles, .trash]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sections, id: \.0) { title, items in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).panelHeader().padding(.horizontal, 10).padding(.bottom, 4)
                        ForEach(items, id: \.self) { item in
                            Button { library.destination = item } label: {
                                Label(item.title, systemImage: item.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(library.destination == item ? Theme.panelRaised : .clear))
                                    .foregroundStyle(library.destination == item ? Theme.text : Theme.textSecondary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sidebar-\(item.title)")
                        }
                    }
                }
                SidebarAlbums()
            }
            .padding(10)
        }
        .background(Theme.panel)
    }
}

/// Recent albums in the sidebar: click to open, drop photos to add them.
struct SidebarAlbums: View {
    @EnvironmentObject var library: LibraryModel
    @State private var targeted: String?

    var body: some View {
        let recent = library.recentAlbumIDs.compactMap { id in library.albums.first { $0.id == id } }
        let shown = (recent + library.albums.filter { a in !recent.contains { $0.id == a.id } }).prefix(10)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Albums").panelHeader().padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(Array(shown), id: \.id) { album in
                    Button { library.destination = .album(album.id) } label: {
                        HStack(spacing: 6) {
                            AlbumCover(album: album, size: 18)
                            Text(album.albumName).lineLimit(1)
                            Spacer()
                            Text("\(album.assetCount)").font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(
                            targeted == album.id ? Theme.highlight.opacity(0.35)
                            : (library.destination == .album(album.id) ? Theme.panelRaised : .clear)))
                        .foregroundStyle(library.destination == .album(album.id) ? Theme.text : Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar-album-\(album.albumName)")
                    .dropDestination(for: String.self) { items, _ in
                        let ids = LibraryModel.droppedAssetIDs(items)
                        guard !ids.isEmpty else { return false }
                        library.add(ids, toAlbum: album)
                        return true
                    } isTargeted: { targeted = $0 ? album.id : (targeted == album.id ? nil : targeted) }
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        // Files from Finder: import straight into this album.
                        var urls: [URL] = []
                        let group = DispatchGroup()
                        for p in providers {
                            group.enter()
                            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { urls.append(url) }; group.leave() }
                        }
                        group.notify(queue: .main) { library.importer.scan(urls, album: album) }
                        return true
                    }
                }
            }
        }
    }
}

/// Year/month jump bar along the right edge of the grid.
struct DateScrubber: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var timeline: TimelineStore

    var body: some View {
        let years = Dictionary(grouping: timeline.sections) { Calendar.utc.component(.year, from: $0.date) }
        ScrollView(showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(years.keys.sorted(by: >), id: \.self) { year in
                    Button(String(year)) {
                        if let first = years[year]?.first { library.scrollRequest = first.bucket }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    ForEach(years[year] ?? []) { section in
                        Button(section.date.formatted(.dateTime.month(.abbreviated))) { library.scrollRequest = section.bucket }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 14)
        }
        .frame(maxHeight: .infinity)
    }
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

/// Trash header: count, Restore All, Empty Trash (with confirmation).
struct TrashBar: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var timeline: TimelineStore

    var body: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(Theme.textTertiary)
            Text("Items in the trash are deleted permanently after the period set on your Immich server.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Restore All") { library.restoreAllTrash() }
                .disabled(timeline.totalCount == 0)
                .accessibilityIdentifier("restore-all")
            Button("Empty Trash…") { library.sheet = .confirmEmptyTrash(timeline.totalCount) }
                .disabled(timeline.totalCount == 0)
                .accessibilityIdentifier("empty-trash")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.panel)
    }
}

/// Loading spinner / empty message over the grid.
struct TimelineStatusOverlay: View {
    @ObservedObject var timeline: TimelineStore
    let destination: LibraryDestination

    var body: some View {
        if timeline.sections.isEmpty {
            if timeline.isLoading {
                ProgressView().controlSize(.large).accessibilityIdentifier("grid-loading")
            } else {
                EmptyStateView(destination: destination, error: timeline.error)
            }
        }
    }
}

struct EmptyStateView: View {
    let destination: LibraryDestination
    let error: String?

    private var emptyText: String {
        if case .search = destination { return "No matching photos" }
        return "Nothing here yet"
    }
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: destination.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(error ?? emptyText).foregroundStyle(error == nil ? Theme.textSecondary : Theme.danger)
                .accessibilityIdentifier("empty-state")
        }
    }
}

struct ComingSoonView: View {
    let destination: LibraryDestination
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: destination.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(destination.title).font(.title3.weight(.light)).foregroundStyle(Theme.text)
            Text("This view is being built.").foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.gridBackground)
    }
}
