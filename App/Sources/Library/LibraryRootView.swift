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
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(timeline: library.timeline)
            Divider().overlay(Theme.separator)
            HStack(spacing: 0) {
                if library.showLeftPanel {
                    SidebarView().frame(width: 220)
                    Divider().overlay(Theme.separator)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if library.showRightPanel {
                    Divider().overlay(Theme.separator)
                    InfoPanel().frame(width: 280)
                }
            }
            if let message = library.statusMessage {
                Text(message).font(.caption).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.panel)
            }
        }
        .background(Theme.background)
        .onAppear { installKeyMonitor() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    }

    @ViewBuilder private var content: some View {
        if library.destination.timelineQuery != nil {
            switch library.mode {
            case .grid:
                ZStack(alignment: .trailing) {
                    GridView(timeline: library.timeline)
                    DateScrubber(timeline: library.timeline).frame(width: 64)
                }
                .overlay {
                    if library.timeline.sections.isEmpty && !library.timeline.isLoading {
                        EmptyStateView(destination: library.destination, error: library.timeline.error)
                    }
                }
            default:
                LoupeView()
            }
        } else {
            ComingSoonView(destination: library.destination)
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
        switch event.keyCode {
        case 123 where library.mode != .grid: library.step(-1); return true  // ←
        case 124 where library.mode != .grid: library.step(1); return true   // →
        case 53 where library.mode != .grid: library.mode = .grid; return true // Esc
        default: break
        }
        switch key {
        case "g": library.mode = .grid; return true
        case "e": library.toggleMode(.loupe); return true
        case "i": library.showInfoOverlay.toggle(); return true
        case "f": NSApp.keyWindow?.toggleFullScreen(nil); return true
        case " " where library.mode == .loupe:
            guard library.focusedAsset?.isLivePhoto == true else { return false }
            library.playingLive.toggle(); return true
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
            Text(library.destination.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                .accessibilityIdentifier("destination-title")
            if library.destination.timelineQuery != nil {
                Text("\(timeline.totalCount) items").font(.caption).foregroundStyle(Theme.textTertiary)
                    .accessibilityIdentifier("item-count")
            }
            Spacer()
            if library.destination.timelineQuery != nil {
                Picker("", selection: Binding(get: { library.mode == .grid ? ViewMode.grid : .loupe },
                                              set: { library.mode == $0 ? () : library.toggleMode($0) })) {
                    Image(systemName: "square.grid.3x3").tag(ViewMode.grid).help("Grid (G)")
                    Image(systemName: "rectangle").tag(ViewMode.loupe).help("Loupe (E)")
                }
                .pickerStyle(.segmented).frame(width: 90)
                if library.mode == .grid {
                    Slider(value: $library.gridCellSize, in: 90...480).frame(width: 110).help("Thumbnail size (⌘+ / ⌘−)")
                }
            }
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
        ("Manage", [.archive, .locked, .duplicates, .trash]),
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
            }
            .padding(10)
        }
        .background(Theme.panel)
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

struct EmptyStateView: View {
    let destination: LibraryDestination
    let error: String?
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: destination.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text(error ?? "Nothing here yet").foregroundStyle(error == nil ? Theme.textSecondary : Theme.danger)
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
