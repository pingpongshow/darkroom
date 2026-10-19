import SwiftUI
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
            CommandMenu("Photo") { PhotoCommands() }
            CommandGroup(after: .sidebar) { ViewCommands() }
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
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .openPresetFiles, object: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
