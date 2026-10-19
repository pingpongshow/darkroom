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
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }
}
