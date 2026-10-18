import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

@Suite("Multi-user accounts against the test server", .enabled(if: TestServer.isAvailable), .serialized)
@MainActor
struct AccountIntegrationTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "dr-it-accounts-\(UUID().uuidString)")

    func manager() -> AccountManager {
        AccountManager(store: AccountStore(directory: dir), secrets: InMemorySecretStore())
    }

    @Test func signInSetPINAndSwitchUsers() async throws {
        let manager = manager()
        let creds = try #require(TestServer.credentials)
        let (admin, _) = try await manager.signIn(server: TestServer.url.absoluteString, email: creds.admin.email, password: creds.admin.password)
        let (viewer, _) = try await manager.signIn(server: TestServer.url.absoluteString, email: creds.user.email, password: creds.user.password)
        #expect(manager.accounts.count == 2)
        #expect(admin.isAdmin && !viewer.isAdmin)

        try manager.setPIN("2468", for: admin.id)
        try manager.setPIN("13579", for: viewer.id)

        let adminClient = try manager.unlock(admin.id, pin: "2468")
        #expect(try await adminClient.getMyUser().email == creds.admin.email)
        let viewerClient = try manager.unlock(viewer.id, pin: "13579")
        #expect(try await viewerClient.getMyUser().email == creds.user.email)

        // Re-signing in the same user updates rather than duplicates.
        _ = try await manager.signIn(server: TestServer.url.absoluteString, email: creds.user.email, password: creds.user.password)
        #expect(manager.accounts.count == 2)

        // Accounts persist (without secrets) across launches.
        #expect(AccountStore(directory: dir).load().count == 2)
    }

    @Test func fiveWrongPINsRequirePassword() async throws {
        let manager = manager()
        let creds = try #require(TestServer.credentials)
        let (account, _) = try await manager.signIn(server: TestServer.url.absoluteString, email: creds.user.email, password: creds.user.password)
        try manager.setPIN("9999", for: account.id)
        for attempt in 1...AccountManager.maxPINAttempts {
            #expect(throws: AccountError.wrongPIN(remainingAttempts: AccountManager.maxPINAttempts - attempt)) {
                _ = try manager.unlock(account.id, pin: "0000")
            }
        }
        #expect(throws: AccountError.passwordRequired) { _ = try manager.unlock(account.id, pin: "9999") }
        // Password sign-in clears the lockout.
        _ = try await manager.signIn(server: TestServer.url.absoluteString, email: creds.user.email, password: creds.user.password)
        _ = try manager.unlock(account.id, pin: "9999")
    }

    @Test func signOutEndsTheServerSession() async throws {
        let manager = manager()
        let creds = try #require(TestServer.credentials)
        let (account, client) = try await manager.signIn(server: TestServer.url.absoluteString, email: creds.user.email, password: creds.user.password)
        try manager.setPIN("1357", for: account.id)
        await manager.signOut(account.id)
        await #expect(throws: ImmichError.unauthorized) { _ = try await client.getMyUser() }
        #expect(throws: AccountError.passwordRequired) { _ = try manager.unlock(account.id, pin: "1357") }
    }

    @Test func revokedSessionIsDetected() async throws {
        let manager = manager()
        let creds = try #require(TestServer.credentials)
        let (account, client) = try await manager.signIn(server: TestServer.url.absoluteString, email: creds.user.email, password: creds.user.password)
        #expect(await manager.validateSession(client, accountID: account.id))
        _ = try await client.logout()
        #expect(await manager.validateSession(client, accountID: account.id) == false)
        #expect(manager.account(account.id)?.requiresPassword == true)
    }

    @Test func sessionShowsAsDarkRoomDevice() async throws {
        let manager = manager()
        let creds = try #require(TestServer.credentials)
        let (_, client) = try await manager.signIn(server: TestServer.url.absoluteString, email: creds.user.email, password: creds.user.password)
        let sessions = try await client.getSessions()
        let current = try #require(sessions.first { $0.current })
        #expect(current.deviceType == "DarkRoom")
        #expect(current.deviceOS == "macOS")
        _ = try await client.logout()
    }
}
