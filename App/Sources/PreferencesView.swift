import SwiftUI
import DarkRoomCore

struct PreferencesView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("showMemories", store: .darkRoom) private var showMemories = true
    @AppStorage("slideshowSeconds", store: .darkRoom) private var slideshowSeconds = 4.0
    @AppStorage("slideshowKenBurns", store: .darkRoom) private var kenBurns = true
    @AppStorage("writeMetadataToFiles", store: .darkRoom) private var writeToFiles = true

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $state.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show memories above Photos", isOn: $showMemories)
                Section("Metadata") {
                    Toggle("Write date, location, description, rating and tags into the original files", isOn: $writeToFiles)
                    Text("Changes are also kept in Immich. Rewritten files replace the originals in Immich; the previous file is kept hidden so phones don’t upload it again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Slideshow (⌘↩)") {
                    Stepper("\(Int(slideshowSeconds)) seconds per photo", value: $slideshowSeconds, in: 2...30)
                    Toggle("Slow zoom (Ken Burns)", isOn: $kenBurns)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Lock after inactivity", selection: $state.autoLockMinutes) {
                    Text("Never").tag(0)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                Toggle("Lock when the Mac sleeps", isOn: $state.lockOnSleep)
                if let session = state.session {
                    Section("Signed in as \(session.account.name)") {
                        Toggle("Unlock with Touch ID", isOn: Binding(
                            get: { state.accounts.account(session.account.id)?.touchIDEnabled ?? false },
                            set: { try? state.accounts.setTouchID($0, for: session.account.id) }))
                            .disabled(!AccountManager.biometricsAvailable)
                        Button("Change DarkRoom PIN…") { state.phase = .setPIN(session.account.id) }
                        Button("Sign Out of Immich", role: .destructive) { Task { await state.signOutCurrent() } }
                    }
                }
            }
            .tabItem { Label("Accounts", systemImage: "person.2") }

            EditorsPreferences()
                .tabItem { Label("Editors", systemImage: "arrow.up.forward.app") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }
}

/// Default companion editors per file type, and whether to keep layered files.
struct EditorsPreferences: View {
    @AppStorage("editorRAW", store: .darkRoom) private var rawEditor = ""
    @AppStorage("editorImage", store: .darkRoom) private var imageEditor = ""
    @AppStorage("keepEditableFiles", store: .darkRoom) private var keep = false
    @State private var editors: [CompanionEditor] = []

    var body: some View {
        Form {
            Picker("RAW files", selection: $rawEditor) {
                Text("Automatic (darktable if installed)").tag("")
                ForEach(editors.filter(\.handlesRAW)) { Text($0.name).tag($0.id) }
            }
            Picker("JPEG / HEIC / PNG", selection: $imageEditor) {
                Text("Automatic (PhotoCraft if installed)").tag("")
                ForEach(editors) { Text($0.name).tag($0.id) }
            }
            Toggle("Keep editable files (layers, sidecars) on this Mac by default", isOn: $keep)
            Text("Closing the photo in the editor uploads the result as the edited version. Kept files stay on this Mac only.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Show Kept Edits in Finder") {
                let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "DarkRoom")
                NSWorkspace.shared.activateFileViewerSelecting([base])
            }
        }
        .task { editors = CompanionEditor.installed() }
    }
}
