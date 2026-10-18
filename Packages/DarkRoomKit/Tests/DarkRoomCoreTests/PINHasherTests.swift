import Foundation
import Testing
@testable import DarkRoomCore

@Suite struct PINHasherTests {
    @Test func validFormats() {
        #expect(PINHasher.isValidFormat("1234"))
        #expect(PINHasher.isValidFormat("123456"))
        #expect(!PINHasher.isValidFormat("123"))
        #expect(!PINHasher.isValidFormat("1234567"))
        #expect(!PINHasher.isValidFormat("12a4"))
        #expect(!PINHasher.isValidFormat("١٢٣٤")) // non-ASCII digits
    }

    @Test func verifiesOnlyTheRightPIN() {
        let hash = PINHasher.make("4821", iterations: 1_000)
        #expect(PINHasher.verify("4821", against: hash))
        #expect(!PINHasher.verify("4822", against: hash))
        #expect(!PINHasher.verify("48210", against: hash))
    }

    @Test func saltsDiffer() {
        let a = PINHasher.make("1111", iterations: 1_000)
        let b = PINHasher.make("1111", iterations: 1_000)
        #expect(a.salt != b.salt)
        #expect(a.hash != b.hash)
    }

    @Test func accountStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dr-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AccountStore(directory: dir)
        #expect(store.load().isEmpty)
        let account = Account(id: UUID(), serverURL: URL(string: "http://localhost:2283")!, userID: "u1",
                              email: "a@darkroom.test", name: "Ada Lovelace", avatarColor: "blue", isAdmin: false,
                              createdAt: .now, lastUsedAt: .now, hasPIN: true, touchIDEnabled: false,
                              failedPINAttempts: 0, requiresPassword: false)
        try store.save([account])
        #expect(store.load() == [account])
        #expect(account.initials == "AL")
    }
}
