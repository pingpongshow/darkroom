import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

/// A signed-in, unlocked user: their account and an authenticated API client.
@MainActor
final class UserSession: ObservableObject, Identifiable {
    nonisolated let id: UUID
    let account: Account
    let client: ImmichClient

    init(account: Account, client: ImmichClient) {
        self.id = account.id
        self.account = account
        self.client = client
    }
}

/// Top-level navigation: user picker → sign-in → PIN setup → unlock → library.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case picker
        case signIn(prefillAccount: UUID?)
        case setPIN(UUID)
        case unlock(UUID)
        case library
    }

    @Published var phase: Phase = .picker
    @Published private(set) var session: UserSession?
    @AppStorage("appearance") var appearance: AppearanceSetting = .dark {
        didSet { applyAppearance() }
    }
    @AppStorage("autoLockMinutes") var autoLockMinutes: Int = 15
    @AppStorage("lockOnSleep") var lockOnSleep: Bool = true

    let accounts: AccountManager
    private var observers: [NSObjectProtocol] = []
    private var lastActivity = Date()
    private var idleTimer: Timer?

    /// UI tests launch DarkRoom with an isolated data folder and an in-memory secret store
    /// (`DARKROOM_DATA_DIR`, `DARKROOM_SECRETS=memory`), so they never touch real accounts.
    static func makeAccountManager() -> AccountManager {
        let env = ProcessInfo.processInfo.environment
        let store = env["DARKROOM_DATA_DIR"].map { AccountStore(directory: URL(fileURLWithPath: $0)) } ?? AccountStore()
        let secrets: SecretStore = env["DARKROOM_SECRETS"] == "memory" ? InMemorySecretStore() : KeychainStore()
        return AccountManager(store: store, secrets: secrets)
    }

    init(accounts: AccountManager = AppState.makeAccountManager()) {
        self.accounts = accounts
        phase = accounts.accounts.isEmpty ? .signIn(prefillAccount: nil) : .picker
        applyAppearance()
        observeLocking()
    }

    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    // MARK: Flow

    /// Called after a successful password sign-in.
    func didSignIn(account: Account, client: ImmichClient) {
        if account.hasPIN {
            open(account: account, client: client)
        } else {
            pendingClient = client
            phase = .setPIN(account.id)
        }
    }

    /// Client kept between sign-in and PIN setup.
    private var pendingClient: ImmichClient?

    func didSetPIN(for accountID: UUID) {
        guard let account = accounts.account(accountID) else { phase = .picker; return }
        if let client = pendingClient {
            pendingClient = nil
            open(account: account, client: client)
        } else {
            phase = .unlock(accountID)
        }
    }

    func choose(_ account: Account) {
        if account.requiresPassword || !account.hasPIN {
            phase = .signIn(prefillAccount: account.id)
        } else {
            phase = .unlock(account.id)
        }
    }

    func open(account: Account, client: ImmichClient) {
        session = UserSession(account: accounts.account(account.id) ?? account, client: client)
        phase = .library
        lastActivity = .now
        Task { [weak self] in
            guard let self else { return }
            if await !self.accounts.validateSession(client, accountID: account.id) {
                self.lock()
                self.phase = .signIn(prefillAccount: account.id)
            }
        }
    }

    /// Returns to the user picker (keeps the session token so the PIN unlocks instantly).
    func lock() {
        session = nil
        pendingClient = nil
        phase = accounts.accounts.isEmpty ? .signIn(prefillAccount: nil) : .picker
    }

    func signOutCurrent() async {
        guard let id = session?.account.id else { return }
        lock()
        await accounts.signOut(id)
    }

    // MARK: Auto-lock

    func noteActivity() { lastActivity = .now }

    private func observeLocking() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lockOnSleep, self.session != nil else { return }
                self.lock()
            }
        })
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session != nil, self.autoLockMinutes > 0 else { return }
                // Idle only when both the system (any input) and this app have seen no activity.
                let anyInput = CGEventType(rawValue: ~0)!
                let systemIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
                let appIdle = Date.now.timeIntervalSince(self.lastActivity)
                if min(systemIdle, appIdle) > Double(self.autoLockMinutes * 60) { self.lock() }
            }
        }
    }
}
