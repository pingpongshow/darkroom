import AppIntents
import AppKit
import ImmichAPI
import DarkRoomCore

/// Shortcuts actions run inside DarkRoom and use the user who is currently unlocked, so the DarkRoom PIN
/// still protects each account on a shared Mac.
enum IntentAccount {
    /// Set by AppState when a user unlocks; cleared when DarkRoom locks.
    @MainActor static var activeClient: ImmichClient?

    @MainActor
    static func client() throws -> ImmichClient {
        guard let client = activeClient else { throw IntentError.locked }
        return client
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case locked
        var localizedStringResource: LocalizedStringResource { "Open DarkRoom and unlock your library first." }
    }
}

struct UploadToImmichIntent: AppIntent {
    static let title: LocalizedStringResource = "Upload to Immich"
    static let description = IntentDescription("Uploads photos and videos to Immich with DarkRoom (duplicates are skipped).")

    @Parameter(title: "Files", supportedContentTypes: [.image, .movie])
    var files: [IntentFile]

    @Parameter(title: "Album name", default: nil)
    var album: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let client = try IntentAccount.client()
        let folder = FileManager.default.temporaryDirectory.appending(path: "darkroom-intent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var urls: [URL] = []
        for file in files {
            let url = folder.appending(path: file.filename)
            try file.data.write(to: url)
            urls.append(url)
        }
        var items = await ImportScanner.items(from: ImportScanner.files(in: urls))
        try await ImportScanner.markExisting(&items, client: client)
        var options = ImportOptions()
        options.newAlbumName = album
        let queue = ImportQueue(client: client, file: folder.appending(path: "queue.json"))
        _ = await queue.add(items.filter(\.isSelected), options: options)
        await queue.run()
        return .result(value: items.filter(\.isSelected).count)
    }
}

struct SearchImmichIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Immich"
    static let description = IntentDescription("Smart-searches your Immich library and returns the file names that match.")

    @Parameter(title: "Search for")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let client = try IntentAccount.client()
        let results = try await SearchService.run(SearchQuery(text: query), client: client, limit: 50)
        return .result(value: results.map(\.originalFileName))
    }
}

struct OpenAlbumIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Album in DarkRoom"
    static let openAppWhenRun = true

    @Parameter(title: "Album name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .openAlbumNamed, object: name)
        return .result()
    }
}

struct DarkRoomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: UploadToImmichIntent(), phrases: ["Upload to Immich with \(.applicationName)"],
                    shortTitle: "Upload to Immich", systemImageName: "icloud.and.arrow.up")
        AppShortcut(intent: SearchImmichIntent(), phrases: ["Search Immich with \(.applicationName)"],
                    shortTitle: "Search Immich", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenAlbumIntent(), phrases: ["Open an album in \(.applicationName)"],
                    shortTitle: "Open Album", systemImageName: "rectangle.stack")
    }
}

extension Notification.Name {
    static let openAlbumNamed = Notification.Name("DarkRoom.openAlbumNamed")
}
