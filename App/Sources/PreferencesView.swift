import SwiftUI
import DarkRoomCore

struct PreferencesView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $state.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
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
        .frame(width: 480, height: 320)
    }
}
