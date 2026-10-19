import SwiftUI
import DarkRoomCore
import AppKit

@main
struct DarkRoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("DarkRoom", id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 960, minHeight: 640)
                .background(Theme.background)
                .preferredColorScheme(state.appearance == .system ? nil : (state.appearance == .dark ? .dark : .light))
        }
        .defaultSize(width: 1280, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Lock DarkRoom") { state.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(state.session == nil)
                Button("Switch User…") { state.lock() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(state.session == nil)
            }
            CommandGroup(replacing: .importExport) { FileCommands() }
            CommandMenu("Photo") { PhotoCommands() }
            CommandGroup(after: .sidebar) { ViewCommands() }
            CommandGroup(replacing: .help) { HelpCommands() }
        }

        MenuBarExtra("DarkRoom", systemImage: "camera.aperture") {
            MenuBarStatus().environmentObject(state)
        }

        Settings {
            PreferencesView()
                .environmentObject(state)
        }
    }
}

extension Notification.Name {
    /// Preset / profile files opened from Finder (double-click or Dock drop).
    static let openPresetFiles = Notification.Name("DarkRoom.openPresetFiles")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = ServicesProvider()

    func application(_ application: NSApplication, open urls: [URL]) {
        let presets = urls.filter { ["darkroom-preset", "xmp", "cube", "lrtemplate"].contains($0.pathExtension.lowercased()) }
        if !presets.isEmpty { NotificationCenter.default.post(name: .openPresetFiles, object: presets) }
        let media = urls.filter { !presets.contains($0) }
        if !media.isEmpty { NotificationCenter.default.post(name: .importFiles, object: media) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        RenderEngine.exiftoolURL = Bundle.main.url(forResource: "exiftool", withExtension: nil, subdirectory: "exiftool")
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        TipsSetup.configure()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Switches between the account screens and the library.
struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            switch state.phase {
            case .picker:
                UserPickerView()
            case .signIn(let accountID):
                SignInView(prefill: accountID.flatMap { state.accounts.account($0) })
            case .setPIN(let accountID):
                PINSetupView(accountID: accountID)
            case .unlock(let accountID):
                UnlockView(accountID: accountID)
            case .library:
                if let session = state.session {
                    LibraryRootView().environmentObject(session)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.phase)
    }
}

/// Menu-bar Photo menu: the same actions as the right-click menu, for the current selection.
struct PhotoCommands: View {
    @FocusedObject private var library: LibraryModel?

    var body: some View {
        if let library {
            MenuEntriesView(entries: library.assetMenu(includeOpen: false), bindShortcuts: true)
            Divider()
            Button("New Album…") { library.sheet = .newAlbum(library.targetIDs) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        } else {
            Text("Sign in to organise photos")
        }
    }
}

struct ViewCommands: View {
    @FocusedObject private var library: LibraryModel?

    var body: some View {
        Button("Find") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(library == nil)
        Button("Back") { library?.goBack() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(library?.canGoBack != true)
        Divider()
    }
}

struct FileCommands: View {
    @FocusedObject private var library: LibraryModel?
    var body: some View {
        Button("Import…") { library?.importer.choose() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(library == nil)
        Button("Import Presets & Profiles…") { library?.importPresetsWithPanel() }.disabled(library == nil)
        Button("Retry Failed Uploads") { library?.importer.retry() }.disabled(library == nil)
        Divider()
        Button("Export…") { if let l = library { l.sheet = .export(l.targetIDs) } }
            .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(library?.targetIDs.isEmpty != false)
    }
}

struct HelpCommands: View {
    @FocusedObject private var library: LibraryModel?
    var body: some View {
        Button("Keyboard Shortcuts") { library?.sheet = .shortcuts }.keyboardShortcut("/", modifiers: .command).disabled(library == nil)
        Button("Show Tour") { library?.sheet = .tour }.disabled(library == nil)
        Button("DarkRoom User Guide") {
            if let url = Bundle.main.url(forResource: "UserGuide", withExtension: "md") { NSWorkspace.shared.open(url) }
        }
    }
}
