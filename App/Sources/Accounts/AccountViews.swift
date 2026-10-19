import SwiftUI
import ImmichAPI
import DarkRoomCore

// MARK: - Shared chrome

/// Centered card used by all account screens.
struct AccountCard<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("DarkRoom").font(.system(size: 13, weight: .semibold)).tracking(4).foregroundStyle(Theme.textTertiary)
                Text(title).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
            }
            content
        }
        .padding(40)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct AvatarView: View {
    let account: Account
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle().fill(Theme.avatar(account.avatarColor))
            Text(account.initials).font(.system(size: size * 0.36, weight: .medium)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(account.name)
    }
}

// MARK: - User picker

struct UserPickerView: View {
    @EnvironmentObject var state: AppState
    @State private var removing: Account?

    var body: some View {
        AccountCard(title: "Who’s editing?") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 24)], spacing: 24) {
                ForEach(state.accounts.accounts) { account in
                    Button { state.choose(account) } label: {
                        VStack(spacing: 10) {
                            AvatarView(account: account)
                            Text(account.name).foregroundStyle(Theme.text).lineLimit(1)
                            Text(account.requiresPassword ? "Password needed" : account.touchIDEnabled ? "PIN or Touch ID" : "PIN")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Sign in with password…") { state.phase = .signIn(prefillAccount: account.id) }
                        Divider()
                        Button("Remove from this Mac…", role: .destructive) { removing = account }
                    }
                    .accessibilityIdentifier("account-\(account.email)")
                }
                Button { state.phase = .signIn(prefillAccount: nil) } label: {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().strokeBorder(Theme.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            Image(systemName: "plus").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(width: 72, height: 72)
                        Text("Add User").foregroundStyle(Theme.textSecondary)
                        Text(" ").font(.caption)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("add-user")
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "") from this Mac?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = removing?.id { Task { await state.accounts.remove(id) } }
                removing = nil
            }
        } message: {
            Text("This signs them out and forgets their DarkRoom PIN on this Mac. Their Immich library isn’t affected.")
        }
    }
}

// MARK: - Sign in (standard Immich sign-in)

struct SignInView: View {
    @EnvironmentObject var state: AppState
    let prefill: Account?

    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var found: [DiscoveredServer] = []
    @State private var scanning = false
    @State private var manualEntry = false
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        AccountCard(title: prefill == nil ? "Sign in to Immich" : "Welcome back, \(prefill!.name.split(separator: " ").first.map(String.init) ?? "")",
                    subtitle: prefill == nil ? "Use the same email and password as Immich on the web." : "Enter your Immich password to continue.") {
            VStack(alignment: .leading, spacing: 12) {
                if prefill == nil {
                    discoverySection
                    if manualEntry || (!scanning && found.isEmpty) {
                        field("Server address", text: $server, prompt: "http://immich.local:2283", id: "server")
                    }
                } else {
                    field("Server", text: $server, prompt: "", id: "server").disabled(true)
                }
                field("Email", text: $email, prompt: "you@example.com", id: "email")
                    .disabled(prefill != nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password").panelHeader()
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                        .accessibilityIdentifier("password")
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(Theme.danger).accessibilityIdentifier("sign-in-error")
                }
                HStack {
                    if !state.accounts.accounts.isEmpty {
                        Button("Back") { state.phase = .picker }
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Sign In", action: signIn)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || server.isEmpty || email.isEmpty || password.isEmpty)
                        .accessibilityIdentifier("sign-in")
                }
                .padding(.top, 8)
            }
            .frame(width: 360)
        }
        .onAppear {
            if let prefill {
                server = prefill.serverURL.absoluteString
                email = prefill.email
            } else {
                if server.isEmpty, let last = state.accounts.accounts.first { server = last.serverURL.absoluteString }
                startScan()
            }
        }
        .onDisappear { scanTask?.cancel() }
    }

    // MARK: Automatic discovery

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Servers on your network").panelHeader()
                Spacer()
                if scanning {
                    ProgressView().controlSize(.mini)
                    Text("Searching…").font(.caption).foregroundStyle(Theme.textTertiary)
                } else {
                    Button("Search Again", action: startScan).buttonStyle(.link).font(.caption)
                        .accessibilityIdentifier("rescan")
                }
            }
            if found.isEmpty && !scanning {
                Text("No Immich server found automatically. Enter its address below.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("discovery-empty")
            }
            ForEach(found) { candidate in
                Button {
                    server = candidate.url.absoluteString
                    manualEntry = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: server == candidate.url.absoluteString ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(server == candidate.url.absoluteString ? Theme.highlight : Theme.textTertiary)
                        Image(systemName: "server.rack").foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.displayName).foregroundStyle(Theme.text)
                            Text("Immich \(candidate.version)").font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("found-\(candidate.displayName)")
            }
            if !found.isEmpty && !manualEntry {
                Button("Enter address manually") { manualEntry = true }.buttonStyle(.link).font(.caption)
                    .accessibilityIdentifier("manual-entry")
            }
        }
    }

    private func startScan() {
        scanTask?.cancel()
        found = []
        scanning = true
        let known = state.accounts.accounts.map(\.serverURL)
        let discovery = ServerDiscovery(knownServers: known)
        scanTask = Task {
            for await candidate in discovery.scan(candidates: nil) {
                found.append(candidate)
                if found.count == 1 && (server.isEmpty || !manualEntry) { server = candidate.url.absoluteString }
            }
            scanning = false
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).panelHeader()
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier(id)
        }
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let (account, client) = try await state.accounts.signIn(server: server, email: email, password: password)
                password = ""
                state.didSignIn(account: account, client: client)
            } catch ImmichError.http(let status, _, _) where status == 401 || status == 400 {
                error = "Incorrect email or password."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - PIN setup

struct PINSetupView: View {
    @EnvironmentObject var state: AppState
    let accountID: UUID

    @State private var pin = ""
    @State private var confirm = ""
    @State private var useTouchID = AccountManager.biometricsAvailable
    @State private var error: String?

    var body: some View {
        AccountCard(title: "Create your DarkRoom PIN",
                    subtitle: "Used to switch to your library quickly on this Mac. It stays on this Mac and is separate from Immich’s locked-folder PIN.") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PIN (4–6 digits)").panelHeader()
                    SecureField("", text: $pin).textFieldStyle(.roundedBorder).accessibilityIdentifier("pin")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm PIN").panelHeader()
                    SecureField("", text: $confirm).textFieldStyle(.roundedBorder).onSubmit(save).accessibilityIdentifier("pin-confirm")
                }
                if AccountManager.biometricsAvailable {
                    Toggle("Also unlock with Touch ID", isOn: $useTouchID)
                }
                if let error { Text(error).font(.callout).foregroundStyle(Theme.danger) }
                HStack {
                    Spacer()
                    Button("Continue", action: save).keyboardShortcut(.defaultAction)
                        .disabled(pin.isEmpty || confirm.isEmpty)
                        .accessibilityIdentifier("pin-save")
                }
            }
            .frame(width: 320)
        }
    }

    private func save() {
        guard PINHasher.isValidFormat(pin) else { error = AccountError.invalidPINFormat.localizedDescription; return }
        guard pin == confirm else { error = "The PINs don’t match."; return }
        do {
            try state.accounts.setPIN(pin, for: accountID)
            if useTouchID { try? state.accounts.setTouchID(true, for: accountID) }
            state.didSetPIN(for: accountID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Unlock

struct UnlockView: View {
    @EnvironmentObject var state: AppState
    let accountID: UUID

    @State private var pin = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        if let account = state.accounts.account(accountID) {
            AccountCard(title: account.name, subtitle: account.email) {
                VStack(spacing: 16) {
                    AvatarView(account: account, size: 96)
                    SecureField("PIN", text: $pin)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .onSubmit(unlock)
                        .onChange(of: pin) { _, value in
                            if value.count == 6 { unlock() }
                        }
                        .accessibilityIdentifier("unlock-pin")
                    if let error { Text(error).font(.callout).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
                    HStack(spacing: 12) {
                        Button("Back") { state.phase = .picker }
                        if account.touchIDEnabled && AccountManager.biometricsAvailable {
                            Button { touchID() } label: { Label("Touch ID", systemImage: "touchid") }
                        }
                        Button("Unlock", action: unlock).keyboardShortcut(.defaultAction).disabled(pin.count < 4)
                            .accessibilityIdentifier("unlock")
                    }
                    Button("Use password instead") { state.phase = .signIn(prefillAccount: accountID) }
                        .buttonStyle(.link)
                }
            }
            .task {
                // Focus after the view is in the window so typing goes straight to the PIN.
                try? await Task.sleep(for: .milliseconds(150))
                focused = true
                if account.touchIDEnabled && AccountManager.biometricsAvailable { touchID() }
            }
        }
    }

    private func unlock() {
        do {
            let client = try state.accounts.unlock(accountID, pin: pin)
            if let account = state.accounts.account(accountID) { state.open(account: account, client: client) }
        } catch AccountError.passwordRequired {
            state.phase = .signIn(prefillAccount: accountID)
        } catch AccountError.sessionMissing {
            state.phase = .signIn(prefillAccount: accountID)
        } catch {
            self.error = error.localizedDescription
            pin = ""
            if case AccountError.wrongPIN(let remaining) = error, remaining == 0 {
                state.phase = .signIn(prefillAccount: accountID)
            }
        }
    }

    private func touchID() {
        Task {
            do {
                let client = try await state.accounts.unlockWithBiometrics(accountID)
                if let account = state.accounts.account(accountID) { state.open(account: account, client: client) }
            } catch AccountError.passwordRequired {
                state.phase = .signIn(prefillAccount: accountID)
            } catch {
                // Fall back to PIN silently on cancel/failure.
            }
        }
    }
}
