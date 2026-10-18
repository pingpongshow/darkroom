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
        }

        Settings {
            PreferencesView()
                .environmentObject(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
