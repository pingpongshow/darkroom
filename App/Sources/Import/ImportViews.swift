import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ImmichAPI
import DarkRoomCore

/// Import: pick files/folders from any disk (or drop them), review, choose options, upload to Immich.
@MainActor
final class ImportModel: ObservableObject {
    @Published var items: [ImportItem] = []
    @Published var scanning = false
    @Published var checking = false
    @Published var options = ImportOptions()
    @Published var progress: (done: Int, total: Int, current: String)?
    @Published var isPaused = false
    @Published var lastError: String?
    @Published var pendingCard: URL?
    let queue: ImportQueue
    var queueClient: ImmichClient { library.client }
    private unowned let library: LibraryModel
    private var watcher: FolderWatcher?
    private var mountObserver: NSObjectProtocol?

    init(library: LibraryModel) {
        self.library = library
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DarkRoom/\(library.session.account.id.uuidString)/import-queue.json")
        queue = ImportQueue(client: library.client, file: file)
        Task { if await queue.pendingCount > 0 { library.flash("Resuming an unfinished import…"); await run() } }
        watcher = FolderWatcher(importer: self, accountID: library.session.account.id)
        // UI tests can't drive a file picker; they pass paths to review instead.
        if let paths = ProcessInfo.processInfo.environment["DARKROOM_TEST_IMPORT"], ProcessInfo.processInfo.environment["DARKROOM_DATA_DIR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }) }
        }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL, let card = ImportModel.cardRoot(volume) else { return }
            MainActor.assumeIsolated { self?.pendingCard = card }
        }
    }

    /// File picker (any disk, folders searched recursively).
    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Review Import"
        panel.message = "Choose photos, videos or folders to upload to Immich"
        guard panel.runModal() == .OK else { return }
        scan(panel.urls)
    }

    func scan(_ urls: [URL], album: AlbumResponseDto? = nil) {
        if let album { options.albumID = album.id; options.newAlbumName = nil }
        scanning = true
        library.sheet = .importReview
        Task {
            let found = await ImportScanner.items(from: ImportScanner.files(in: urls))
            items = found
            scanning = false
            checking = true
            var checked = found
            try? await ImportScanner.markExisting(&checked, client: library.client)
            items = checked
            checking = false
        }
    }

    var selected: [ImportItem] { items.filter(\.isSelected) }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size + (($1.motion.flatMap { ImportScanner.fileSizePublic($0) }) ?? 0) } }

    func start() {
        let chosen = selected
        guard !chosen.isEmpty else { return }
        let options = self.options
        Task {
            _ = await queue.add(chosen, options: options)
            items = []
            await run()
        }
    }

    func run() async {
        progress = (0, 0, "")
        await queue.run { [weak self] done, total, name in
            Task { @MainActor in self?.progress = (done, total, name) }
        }
        let failed = await queue.jobs.reduce(0) { $0 + $1.failed.count }
        progress = nil
        library.flash(failed == 0 ? "Import finished" : "Import finished with \(failed) failure\(failed == 1 ? "" : "s") (Retry from the import menu)",
                      isError: failed > 0)
        await library.timeline.reload()
        await library.loadAlbums()
    }

    func togglePause() {
        isPaused.toggle()
        let paused = isPaused
        Task { await queue.setPaused(paused) }
    }

    func retry() {
        Task { await queue.retryFailed(); await run() }
    }
}

extension ImportScanner {
    static func fileSizePublic(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
}

struct ImportSheet: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var model: ImportModel
    @State private var tagText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import to Immich").font(.headline)
                Spacer()
                if model.scanning || model.checking {
                    ProgressView().controlSize(.small)
                    Text(model.scanning ? "Finding photos…" : "Checking what’s already in Immich…").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(model.selected.count) of \(model.items.count) selected · \(ByteCountFormatter.string(fromByteCount: model.selectedBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("import-summary")
                Spacer()
                Button("Select All New") { for i in model.items.indices { model.items[i].isSelected = !model.items[i].alreadyInImmich } }
                Button("Select None") { for i in model.items.indices { model.items[i].isSelected = false } }
            }
            .controlSize(.small)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach($model.items) { $item in ImportTile(item: $item) }
                }
            }
            .frame(width: 720, height: 230)
            .background(Theme.gridBackground)
            Form {
                Picker("Album", selection: Binding(get: { model.options.albumID ?? (model.options.newAlbumName != nil ? "new" : "") },
                                                   set: { v in
                    model.options.albumID = (v.isEmpty || v == "new") ? nil : v
                    model.options.newAlbumName = v == "new" ? (model.options.newAlbumName ?? "") : nil
                })) {
                    Text("None").tag("")
                    Text("New Album…").tag("new")
                    ForEach(library.albums, id: \.id) { Text($0.albumName).tag($0.id) }
                }
                if model.options.newAlbumName != nil {
                    TextField("New album name", text: Binding(get: { model.options.newAlbumName ?? "" }, set: { model.options.newAlbumName = $0 }))
                }
                TextField("Tags (comma separated)", text: $tagText)
                    .onChange(of: tagText) { _, v in model.options.tags = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                Picker("RAW+JPEG stacks", selection: $model.options.rawOnTop) { Text("RAW on top").tag(true); Text("JPEG on top").tag(false) }
                Toggle("Mark as favourite", isOn: $model.options.favorite)
                Toggle("Archive", isOn: $model.options.archive)
            }
            .formStyle(.grouped).frame(width: 720, height: 210)
            HStack {
                Text("Original files stay where they are; nothing on your disk is changed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.items = []; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Upload \(model.selected.count)") { model.start(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected.isEmpty || model.scanning)
                    .accessibilityIdentifier("import-start")
            }
        }
        .padding(20)
    }
}

struct ImportTile: View {
    @Binding var item: ImportItem
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.panelRaised)
                if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFill() }
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isSelected ? Theme.highlight : .white).shadow(radius: 2).padding(4)
                if item.alreadyInImmich {
                    Text("In Immich").font(.caption2.weight(.semibold)).padding(3).background(.black.opacity(0.6)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 110, height: 90).clipped()
            .opacity(item.alreadyInImmich ? 0.5 : 1)
            Text(item.file.lastPathComponent).font(.caption2).lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .onTapGesture { item.isSelected.toggle() }
        .task(id: item.file) {
            let request = QLThumbnailGenerator.Request(fileAt: item.file, size: CGSize(width: 220, height: 180), scale: 1, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        }
        .accessibilityIdentifier("import-item-\(item.file.lastPathComponent)")
    }

    private var label: String {
        switch item.kind {
        case .livePhoto: "Live Photo"
        case .raw: item.partner != nil ? "RAW + JPEG" : "RAW"
        case .video: "Video"
        case .photo: "Photo"
        }
    }
}

/// Upload progress under the content area (and in the menu bar).
struct ImportProgressBar: View {
    @ObservedObject var model: ImportModel
    var body: some View {
        if let p = model.progress {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(Theme.highlight)
                ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0).frame(width: 160)
                Text("Uploading \(p.done) of \(p.total)\(p.current.isEmpty ? "" : " · \(p.current)")").font(.caption).lineLimit(1)
                    .accessibilityIdentifier("import-progress")
                Spacer()
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.panelRaised)
        }
    }
}

// MARK: Cards, watched folders, Finder service

extension ImportModel {
    /// A camera card / device appeared (has a DCIM folder).
    static func cardRoot(_ volume: URL) -> URL? {
        let dcim = volume.appending(path: "DCIM")
        return FileManager.default.fileExists(atPath: dcim.path) ? dcim : nil
    }
}

/// Watches folders chosen in Preferences and uploads new photos/videos automatically.
@MainActor
final class FolderWatcher {
    private weak var importer: ImportModel?
    private var timer: Timer?
    private var seen: Set<String>
    private let seenKey: String

    init(importer: ImportModel, accountID: UUID) {
        self.importer = importer
        seenKey = "watchedSeen-\(accountID.uuidString)"
        seen = Set(UserDefaults.darkRoom.stringArray(forKey: seenKey) ?? [])
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scan()
    }

    static var folders: [URL] {
        (UserDefaults.darkRoom.stringArray(forKey: "watchedFolders") ?? []).map { URL(fileURLWithPath: $0) }
    }

    func scan() {
        let folders = Self.folders
        guard !folders.isEmpty else { return }
        let files = ImportScanner.files(in: folders).filter { file in
            // Only files that have stopped changing (fully copied).
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            return !seen.contains(file.path) && Date().timeIntervalSince(modified) > 10
        }
        guard !files.isEmpty else { return }
        files.forEach { seen.insert($0.path) }
        UserDefaults.darkRoom.set(Array(seen.suffix(20000)), forKey: seenKey)
        importer?.autoImport(files)
    }
}

extension ImportModel {
    /// Watched folders: upload straight away (duplicates skipped), no review sheet.
    func autoImport(_ files: [URL]) {
        Task {
            var found = await ImportScanner.items(from: files)
            try? await ImportScanner.markExisting(&found, client: queueClient)
            let new = found.filter(\.isSelected)
            guard !new.isEmpty else { return }
            _ = await queue.add(new, options: ImportOptions())
            await run()
        }
    }
}

/// Finder ▸ Services ▸ Upload to Immich with DarkRoom.
final class ServicesProvider: NSObject {
    @MainActor @objc func uploadFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(name: .importFiles, object: urls)
        NSApp.activate()
    }
}

extension Notification.Name {
    static let importFiles = Notification.Name("DarkRoom.importFiles")
}

/// Banner offered when a camera card is inserted.
struct CardBanner: View {
    @ObservedObject var model: ImportModel
    var body: some View {
        if let card = model.pendingCard {
            HStack {
                Image(systemName: "sdcard").foregroundStyle(Theme.highlight)
                Text("\(card.deletingLastPathComponent().lastPathComponent) inserted").font(.caption)
                Spacer()
                Button("Import…") { model.pendingCard = nil; model.scan([card]) }.controlSize(.small)
                Button("Ignore") { model.pendingCard = nil }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.panelRaised)
        }
    }
}
