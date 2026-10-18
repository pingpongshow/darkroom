import Foundation
import ImmichAPI
import LocalAuthentication

/// A user signed in to DarkRoom on this Mac. Holds no secrets (those live in the `SecretStore`).
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var serverURL: URL
    public var userID: String
    public var email: String
    public var name: String
    public var avatarColor: String?
    public var isAdmin: Bool
    public var createdAt: Date
    public var lastUsedAt: Date
    public var hasPIN: Bool
    public var touchIDEnabled: Bool
    /// Wrong PIN entries since the last successful unlock.
    public var failedPINAttempts: Int
    /// Set after too many wrong PINs or when the server revoked the session: the full password is needed.
    public var requiresPassword: Bool

    public var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? String(email.prefix(1)).uppercased() : letters.uppercased()
    }
}

/// Persists the list of accounts (non-secret data) as JSON in Application Support.
public struct AccountStore: Sendable {
    public let fileURL: URL

    public init(directory: URL = AccountStore.defaultDirectory) {
        fileURL = directory.appending(path: "accounts.json")
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "DarkRoom")
    }

    public func load() -> [Account] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.darkRoom.decode([Account].self, from: data)) ?? []
    }

    public func save(_ accounts: [Account]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.darkRoom.encode(accounts).write(to: fileURL, options: [.atomic])
    }
}

public enum AccountError: Error, LocalizedError, Equatable {
    case invalidPINFormat
    case wrongPIN(remainingAttempts: Int)
    case passwordRequired
    case noPINSet
    case biometricsUnavailable
    case biometricsFailed
    case accountNotFound
    case sessionMissing

    public var errorDescription: String? {
        switch self {
        case .invalidPINFormat: "A PIN must be 4–6 digits."
        case .wrongPIN(let remaining): remaining > 0
            ? "Wrong PIN. \(remaining) attempt\(remaining == 1 ? "" : "s") left before your password is required."
            : "Too many wrong PINs. Please sign in with your password."
        case .passwordRequired: "Please sign in with your Immich password."
        case .noPINSet: "No PIN has been set for this account."
        case .biometricsUnavailable: "Touch ID isn’t available on this Mac."
        case .biometricsFailed: "Touch ID didn’t recognise you."
        case .accountNotFound: "That account no longer exists on this Mac."
        case .sessionMissing: "This account’s session is missing. Please sign in again."
        }
    }
}

/// Multi-user sign-in, quick switching with a DarkRoom PIN or Touch ID, and session lifecycle.
///
/// - First sign-in per user uses standard Immich sign-in (`/auth/login`); the session token is kept
///   in the secret store.
/// - Switching users uses that user's DarkRoom PIN (salted hash, local only) or Touch ID.
/// - Five wrong PINs, or a revoked session, require the user's password again.
@MainActor
public final class AccountManager: ObservableObject {
    public static let maxPINAttempts = 5

    @Published public private(set) var accounts: [Account]
    private let store: AccountStore
    private let secrets: SecretStore
    private let session: URLSession

    public init(store: AccountStore = AccountStore(), secrets: SecretStore = KeychainStore(),
                session: URLSession = .darkRoomDefault) {
        self.store = store
        self.secrets = secrets
        self.session = session
        self.accounts = store.load().sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    // MARK: Sign-in

    /// Standard Immich sign-in. Creates (or refreshes) the account and stores the session token.
    @discardableResult
    public func signIn(server: String, email: String, password: String) async throws -> (Account, ImmichClient) {
        let anonymous = try ImmichClient(server: server, session: session)
        let login = try await anonymous.login(body: LoginCredentialDto(email: email, password: password))
        let client = anonymous.with(credential: .session(login.accessToken))
        let me = try await client.getMyUser()

        var account = accounts.first { $0.serverURL == client.serverURL && $0.userID == me.id } ?? Account(
            id: UUID(), serverURL: client.serverURL, userID: me.id, email: me.email, name: me.name,
            avatarColor: me.avatarColor.rawValue, isAdmin: me.isAdmin, createdAt: .now, lastUsedAt: .now,
            hasPIN: false, touchIDEnabled: false, failedPINAttempts: 0, requiresPassword: false)
        account.email = me.email
        account.name = me.name
        account.isAdmin = me.isAdmin
        account.avatarColor = me.avatarColor.rawValue
        account.lastUsedAt = .now
        account.failedPINAttempts = 0
        account.requiresPassword = false
        try secrets.set(Data(login.accessToken.utf8), for: tokenKey(account.id))
        upsert(account)
        return (account, client)
    }

    // MARK: PIN

    public func setPIN(_ pin: String, for accountID: UUID) throws {
        guard PINHasher.isValidFormat(pin) else { throw AccountError.invalidPINFormat }
        guard var account = account(accountID) else { throw AccountError.accountNotFound }
        let hash = PINHasher.make(pin)
        try secrets.set(try JSONEncoder().encode(hash), for: pinKey(accountID))
        account.hasPIN = true
        account.failedPINAttempts = 0
        upsert(account)
    }

    public func setTouchID(_ enabled: Bool, for accountID: UUID) throws {
        guard var account = account(accountID) else { throw AccountError.accountNotFound }
        if enabled && !Self.biometricsAvailable { throw AccountError.biometricsUnavailable }
        account.touchIDEnabled = enabled
        upsert(account)
    }

    /// Unlocks an account with its PIN and returns an authenticated client.
    public func unlock(_ accountID: UUID, pin: String) throws -> ImmichClient {
        guard var account = account(accountID) else { throw AccountError.accountNotFound }
        if account.requiresPassword { throw AccountError.passwordRequired }
        guard let data = try secrets.get(pinKey(accountID)), let stored = try? JSONDecoder().decode(PINHash.self, from: data) else {
            throw AccountError.noPINSet
        }
        guard PINHasher.verify(pin, against: stored) else {
            account.failedPINAttempts += 1
            if account.failedPINAttempts >= Self.maxPINAttempts {
                account.requiresPassword = true
            }
            upsert(account)
            throw AccountError.wrongPIN(remainingAttempts: max(0, Self.maxPINAttempts - account.failedPINAttempts))
        }
        return try open(&account)
    }

    /// Unlocks an account with Touch ID.
    public func unlockWithBiometrics(_ accountID: UUID, reason: String = "unlock your DarkRoom library") async throws -> ImmichClient {
        guard var account = account(accountID) else { throw AccountError.accountNotFound }
        if account.requiresPassword { throw AccountError.passwordRequired }
        guard account.touchIDEnabled, Self.biometricsAvailable else { throw AccountError.biometricsUnavailable }
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            guard ok else { throw AccountError.biometricsFailed }
        } catch let error as AccountError {
            throw error
        } catch {
            throw AccountError.biometricsFailed
        }
        return try open(&account)
    }

    public static var biometricsAvailable: Bool {
        // UI tests disable Touch ID so PIN flows are exercised deterministically.
        if ProcessInfo.processInfo.environment["DARKROOM_DISABLE_BIOMETRICS"] == "1" { return false }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private func open(_ account: inout Account) throws -> ImmichClient {
        guard let tokenData = try secrets.get(tokenKey(account.id)), let token = String(data: tokenData, encoding: .utf8) else {
            account.requiresPassword = true
            upsert(account)
            throw AccountError.sessionMissing
        }
        account.failedPINAttempts = 0
        account.lastUsedAt = .now
        upsert(account)
        return ImmichClient(serverURL: account.serverURL, credential: .session(token), session: session)
    }

    /// Checks the stored session with the server; marks the account as needing a password if revoked.
    public func validateSession(_ client: ImmichClient, accountID: UUID) async -> Bool {
        do {
            _ = try await client.getMyUser()
            return true
        } catch ImmichError.unauthorized {
            markRequiresPassword(accountID)
            return false
        } catch {
            return true // network problems don't invalidate the session
        }
    }

    public func markRequiresPassword(_ accountID: UUID) {
        guard var account = account(accountID) else { return }
        account.requiresPassword = true
        try? secrets.remove(tokenKey(accountID))
        upsert(account)
    }

    // MARK: Sign-out / removal

    /// Signs out on the server (ends the session) and forgets the token; the account stays in the picker.
    public func signOut(_ accountID: UUID) async {
        if let tokenData = try? secrets.get(tokenKey(accountID)), let token = String(data: tokenData, encoding: .utf8),
           let account = account(accountID) {
            let client = ImmichClient(serverURL: account.serverURL, credential: .session(token), session: session)
            _ = try? await client.logout()
        }
        markRequiresPassword(accountID)
    }

    /// Removes the account from this Mac entirely (sign-out, token, PIN, cached data).
    public func remove(_ accountID: UUID) async {
        await signOut(accountID)
        try? secrets.remove(pinKey(accountID))
        accounts.removeAll { $0.id == accountID }
        try? store.save(accounts)
    }

    // MARK: Helpers

    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    private func upsert(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        accounts.sort { $0.lastUsedAt > $1.lastUsedAt }
        try? store.save(accounts)
    }

    private func tokenKey(_ id: UUID) -> String { "token.\(id.uuidString)" }
    private func pinKey(_ id: UUID) -> String { "pin.\(id.uuidString)" }
}

extension JSONDecoder {
    static let darkRoom: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }()
}

extension JSONEncoder {
    static let darkRoom: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
