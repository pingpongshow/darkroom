import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

extension LibraryModel {
    var albumActions: AlbumActions { AlbumActions(client: client) }

    var currentAlbum: AlbumResponseDto? {
        guard case .album(let id) = destination else { return nil }
        return albums.first { $0.id == id }
    }

    func isOwner(_ album: AlbumResponseDto) -> Bool {
        album.albumUsers.contains { $0.role == .owner && $0.user.id == session.account.userID }
            || (album.albumUsers.allSatisfy { $0.role != .owner })
    }

    func setAlbumCover() {
        guard let album = currentAlbum, let id = targetIDs.first else { return }
        Task {
            do {
                let (_, undo) = try await albumActions.update(album, coverAssetID: id)
                registerSimpleUndo(undo) { await $0.loadAlbums() }
                await loadAlbums()
                flash("Album cover set")
            } catch { flash("Couldn’t set cover: \(error.localizedDescription)", isError: true) }
        }
    }

    func deleteAlbum(_ album: AlbumResponseDto) {
        Task {
            do {
                try await albumActions.delete(album.id)
                if case .album(let id) = destination, id == album.id { destination = .albums }
                await loadAlbums()
                flash("Deleted album “\(album.albumName)” (photos are kept)")
            } catch { flash("Couldn’t delete album: \(error.localizedDescription)", isError: true) }
        }
    }

    func leaveAlbum(_ album: AlbumResponseDto) {
        Task {
            do {
                try await albumActions.removeUser(album.id, userID: "me")
                if case .album(let id) = destination, id == album.id { destination = .albums }
                await loadAlbums()
                flash("Left “\(album.albumName)”")
            } catch { flash("Couldn’t leave album: \(error.localizedDescription)", isError: true) }
        }
    }

    /// Registers an undo for a non-asset change, with a follow-up refresh.
    func registerSimpleUndo(_ undo: UndoAction, then refresh: @escaping @MainActor (LibraryModel) async -> Void) {
        undoManager?.registerUndo(withTarget: self) { model in
            Task { @MainActor in
                do { try await undo.run(); await refresh(model); model.flash("Undo \(undo.name)") }
                catch { model.flash("Couldn’t undo: \(error.localizedDescription)", isError: true) }
            }
        }
        undoManager?.setActionName(undo.name)
    }

    /// Asset ids dropped from the grid ("darkroom-assets:id,id").
    static func droppedAssetIDs(_ strings: [String]) -> [String] {
        strings.flatMap { s -> [String] in
            guard s.hasPrefix(GridDrag.prefix) else { return [] }
            return s.dropFirst(GridDrag.prefix.count).split(separator: ",").map(String.init)
        }
    }

    func add(_ ids: [String], toAlbum album: AlbumResponseDto) {
        recentAlbumIDs.removeAll { $0 == album.id }
        recentAlbumIDs.insert(album.id, at: 0)
        perform("Add to “\(album.albumName)”", ids: ids, change: .albums(ids: ids)) { try await $0.addToAlbum(album.id, ids) }
        Task { try? await Task.sleep(for: .seconds(1)); await loadAlbums() }
    }
}

enum GridDrag { static let prefix = "darkroom-assets:" }

// MARK: Albums overview

struct AlbumsView: View {
    @EnvironmentObject var library: LibraryModel
    enum Filter: String, CaseIterable { case all = "All", mine = "Mine", shared = "Shared with Me" }
    enum Sort: String, CaseIterable { case name = "Name", updated = "Recently Updated", newest = "Newest Photo" }
    @AppStorage("albumFilter", store: .darkRoom) private var filter: Filter = .all
    @AppStorage("albumSort", store: .darkRoom) private var sort: Sort = .updated
    @State private var search = ""
    @State private var deleting: AlbumResponseDto?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { library.sheet = .newAlbum([]) } label: { Label("New Album", systemImage: "plus") }
                    .fixedSize()
                    .accessibilityIdentifier("new-album")
                Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).fixedSize().labelsHidden()
                Spacer(minLength: 8)
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.inline)
                } label: { Label(sort.rawValue, systemImage: "arrow.up.arrow.down") }
                    .fixedSize()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 80, maxWidth: 160)
            }
            .padding(12)
            ScrollView {
                if albums.isEmpty {
                    Text(library.albums.isEmpty ? "No albums yet. Create one, or select photos and press ⇧⌘A." : "No matching albums")
                        .foregroundStyle(Theme.textSecondary).padding(60)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 18)], spacing: 22) {
                    ForEach(albums, id: \.id) { album in
                        AlbumCard(album: album)
                            .onTapGesture { library.destination = .album(album.id) }
                            .contextMenu { albumMenu(album) }
                            .dropDestination(for: String.self) { items, _ in
                                let ids = LibraryModel.droppedAssetIDs(items)
                                guard !ids.isEmpty else { return false }
                                library.add(ids, toAlbum: album)
                                return true
                            }
                    }
                }
                .padding(18)
            }
        }
        .background(Theme.gridBackground)
        .task { await library.loadAlbums() }
        .confirmationDialog("Delete “\(deleting?.albumName ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Album", role: .destructive) { if let deleting { library.deleteAlbum(deleting) } }
        } message: {
            Text("The photos stay in your library. People it’s shared with lose access.")
        }
    }

    private var albums: [AlbumResponseDto] {
        library.albums
            .filter {
                switch filter {
                case .all: true
                case .mine: library.isOwner($0)
                case .shared: !library.isOwner($0)
                }
            }
            .filter { search.isEmpty || $0.albumName.localizedCaseInsensitiveContains(search) }
            .sorted {
                switch sort {
                case .name: $0.albumName.localizedCaseInsensitiveCompare($1.albumName) == .orderedAscending
                case .updated: ($0.lastModifiedAssetTimestamp ?? $0.updatedAt) > ($1.lastModifiedAssetTimestamp ?? $1.updatedAt)
                case .newest: ($0.endDate ?? "") > ($1.endDate ?? "")
                }
            }
    }

    @ViewBuilder private func albumMenu(_ album: AlbumResponseDto) -> some View {
        Button("Open") { library.destination = .album(album.id) }
        if library.isOwner(album) {
            Button("Edit…") { library.sheet = .editAlbum(album.id) }
            Button("Share…") { library.sheet = .shareAlbum(album.id) }
            Button("Get Link…") { library.sheet = .sharedLink(albumID: album.id, assetIDs: []) }
            Divider()
            Button("Delete Album…", role: .destructive) { deleting = album }
        } else {
            Button("Leave Album", role: .destructive) { library.leaveAlbum(album) }
        }
    }
}

struct AlbumCard: View {
    @EnvironmentObject var library: LibraryModel
    let album: AlbumResponseDto

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { AlbumCover(album: album, size: 360).scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if album.shared {
                        Image(systemName: "person.2.fill").font(.caption).padding(5)
                            .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).padding(6)
                    }
                }
            Text(album.albumName).foregroundStyle(Theme.text).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("album-\(album.albumName)")
    }

    private var subtitle: String {
        var parts = ["\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")"]
        if !library.isOwner(album), let owner = album.albumUsers.first(where: { $0.role == .owner }) { parts.append("from \(owner.user.name)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Album header (above the album's grid)

struct AlbumHeader: View {
    @EnvironmentObject var library: LibraryModel
    let album: AlbumResponseDto
    @State private var stats: ActivityStatisticsResponseDto?
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if !album.description.isEmpty {
                    Text(album.description).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let range = dateRange { Text(range) }
                    if album.shared {
                        Text("·")
                        ForEach(album.albumUsers.prefix(6), id: \.user.id) { member in
                            Text(initials(member.user.name))
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Theme.panelRaised))
                                .help("\(member.user.name) (\(member.role.rawValue))")
                        }
                    }
                }
                .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if album.isActivityEnabled && album.shared {
                Button { library.showActivity.toggle() } label: {
                    Label("\(stats?.comments ?? 0)", systemImage: "bubble.left")
                    Label("\(stats?.likes ?? 0)", systemImage: "heart")
                }
                .accessibilityIdentifier("album-activity")
            }
            if library.isOwner(album) {
                Button("Share…") { library.sheet = .shareAlbum(album.id) }.accessibilityIdentifier("album-share")
                Button("Link…") { library.sheet = .sharedLink(albumID: album.id, assetIDs: []) }.accessibilityIdentifier("album-link")
                Menu {
                    Button("Edit…") { library.sheet = .editAlbum(album.id) }
                    Button("Set Selected as Cover") { library.setAlbumCover() }.disabled(library.targetIDs.isEmpty)
                    Divider()
                    Button("Delete Album…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 34)
                    .accessibilityIdentifier("album-more")
            } else {
                Button("Leave Album", role: .destructive) { library.leaveAlbum(album) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.panel)
        .task(id: album.updatedAt) {
            if album.shared { stats = try? await library.client.getActivityStatistics(albumId: album.id) }
        }
        .confirmationDialog("Delete “\(album.albumName)”?", isPresented: $confirmDelete) {
            Button("Delete Album", role: .destructive) { library.deleteAlbum(album) }
        } message: { Text("The photos stay in your library.") }
    }

    private var dateRange: String? {
        guard let start = album.startDate.flatMap(ImmichDate.parse), let end = album.endDate.flatMap(ImmichDate.parse) else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)
        let a = start.formatted(style), b = end.formatted(style)
        return a == b ? a : "\(a) – \(b)"
    }
}

func initials(_ name: String) -> String {
    name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
}

// MARK: Activity (comments and likes)

struct ActivityPanel: View {
    @EnvironmentObject var library: LibraryModel
    let album: AlbumResponseDto
    @State private var feed: [ActivityResponseDto] = []
    @State private var draft = ""
    /// Comments on the photo in the loupe, or on the whole album.
    private var assetID: String? { library.mode == .grid ? nil : library.focusedAssetID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(assetID == nil ? "Album Activity" : "Photo Activity").panelHeader()
                Spacer()
                Button { toggleLike() } label: {
                    Image(systemName: myLike == nil ? "heart" : "heart.fill").foregroundStyle(myLike == nil ? Theme.textSecondary : .pink)
                }
                .buttonStyle(.borderless).accessibilityIdentifier("activity-like")
            }
            .padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if feed.isEmpty { Text("No comments yet").foregroundStyle(Theme.textTertiary) }
                    ForEach(feed, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.user.name).font(.caption.weight(.semibold))
                                if item.type == .like { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
                                Spacer()
                                Text(ImmichDate.parse(item.createdAt)?.formatted(.relative(presentation: .named)) ?? "")
                                    .font(.caption2).foregroundStyle(Theme.textTertiary)
                            }
                            if let comment = item.comment { Text(comment).foregroundStyle(Theme.text).textSelection(.enabled) }
                        }
                        .contextMenu {
                            if item.user.id == library.session.account.userID {
                                Button("Delete", role: .destructive) { delete(item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .font(.system(size: 12))
            }
            HStack {
                TextField("Add a comment", text: $draft).textFieldStyle(.roundedBorder).onSubmit(send)
                    .accessibilityIdentifier("activity-comment")
                Button("Send", action: send).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-panel")
        .task(id: "\(album.id)-\(assetID ?? "")") { await load() }
    }

    private var myLike: ActivityResponseDto? {
        feed.first { $0.type == .like && $0.user.id == library.session.account.userID && $0.assetId == assetID }
    }

    private func load() async {
        feed = (try? await library.albumActions.activity(album.id, assetID: assetID)) ?? []
        if assetID == nil { feed = feed.filter { $0.assetId == nil } }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            do { _ = try await library.albumActions.comment(album.id, assetID: assetID, text: text); await load() }
            catch { library.flash("Couldn’t post comment: \(error.localizedDescription)", isError: true) }
        }
    }

    private func toggleLike() {
        Task {
            try? await library.albumActions.toggleLike(album.id, assetID: assetID, existing: myLike)
            await load()
        }
    }

    private func delete(_ item: ActivityResponseDto) {
        Task { try? await library.client.deleteActivity(id: item.id); await load() }
    }
}

// MARK: Sheets

struct EditAlbumSheet: View {
    @EnvironmentObject var library: LibraryModel
    let albumID: String
    @State private var name = ""
    @State private var description = ""
    @State private var activity = true
    @State private var newestFirst = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Album").font(.headline)
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("edit-album-name")
                TextField("Description", text: $description, axis: .vertical).lineLimit(2...4)
                Toggle("Comments and likes", isOn: $activity)
                Picker("Order", selection: $newestFirst) { Text("Newest first").tag(true); Text("Oldest first").tag(false) }
            }
            .formStyle(.grouped).frame(width: 400)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("sheet-confirm")
            }
        }
        .padding(20)
        .onAppear {
            guard let album else { return }
            name = album.albumName; description = album.description
            activity = album.isActivityEnabled; newestFirst = album.order != .asc
        }
    }

    private var album: AlbumResponseDto? { library.albums.first { $0.id == albumID } }

    private func save() {
        guard let album else { return }
        let name = name.trimmingCharacters(in: .whitespaces), description = description, activity = activity
        let order: AssetOrder = newestFirst ? .desc : .asc
        Task {
            do {
                let (_, undo) = try await library.albumActions.update(album, name: name, description: description,
                                                                       activityEnabled: activity, order: order)
                library.registerSimpleUndo(undo) { await $0.loadAlbums() }
                await library.loadAlbums()
                if case .album(let id) = library.destination, id == album.id { await library.timeline.reload() }
            } catch { library.flash("Couldn’t save album: \(error.localizedDescription)", isError: true) }
        }
    }
}

/// Invite users to an album and manage their roles.
struct ShareAlbumSheet: View {
    @EnvironmentObject var library: LibraryModel
    let albumID: String
    @State private var users: [UserResponseDto] = []
    @State private var album: AlbumResponseDto?
    @State private var newRole: AlbumUserRole = .editor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share “\(album?.albumName ?? "")”").font(.headline)
            Text("People on your Immich server").font(.caption).foregroundStyle(.secondary)
            List {
                if let album {
                    Section("Shared with") {
                        if album.albumUsers.filter({ $0.role != .owner }).isEmpty { Text("Nobody yet").foregroundStyle(.secondary) }
                        ForEach(album.albumUsers.filter { $0.role != .owner }, id: \.user.id) { member in
                            HStack {
                                Text(member.user.name)
                                Text(member.user.email).foregroundStyle(.secondary).font(.caption)
                                Spacer()
                                Picker("", selection: Binding(get: { member.role }, set: { setRole(member.user.id, $0) })) {
                                    Text("Can edit").tag(AlbumUserRole.editor)
                                    Text("Can view").tag(AlbumUserRole.viewer)
                                }
                                .labelsHidden().frame(width: 110)
                                Button { remove(member.user.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("Invite") {
                    Picker("Role for new people", selection: $newRole) {
                        Text("Can edit").tag(AlbumUserRole.editor)
                        Text("Can view").tag(AlbumUserRole.viewer)
                    }
                    ForEach(candidates, id: \.id) { user in
                        HStack {
                            Text(user.name)
                            Text(user.email).foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Button("Invite") { invite(user.id) }.accessibilityIdentifier("invite-\(user.email)")
                        }
                    }
                }
            }
            .frame(width: 480, height: 340)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .task { await load() }
    }

    private var candidates: [UserResponseDto] {
        let members = Set(album?.albumUsers.map(\.user.id) ?? [])
        return users.filter { !members.contains($0.id) && $0.id != library.session.account.userID }
    }

    private func load() async {
        album = try? await library.client.getAlbumInfo(id: albumID)
        users = (try? await library.client.searchUsers()) ?? []
    }

    private func invite(_ userID: String) {
        Task {
            do { album = try await library.albumActions.share(albumID, with: [userID], role: newRole); await library.loadAlbums() }
            catch { library.flash("Couldn’t share: \(error.localizedDescription)", isError: true) }
        }
    }

    private func setRole(_ userID: String, _ role: AlbumUserRole) {
        Task { try? await library.albumActions.setRole(albumID, userID: userID, role: role); await load() }
    }

    private func remove(_ userID: String) {
        Task { try? await library.albumActions.removeUser(albumID, userID: userID); await load(); await library.loadAlbums() }
    }
}

/// Create a public link to an album or to selected photos.
struct SharedLinkSheet: View {
    @EnvironmentObject var library: LibraryModel
    let albumID: String?
    let assetIDs: [String]
    @State private var options = AlbumActions.LinkOptions()
    @State private var expiry = 0
    @State private var created: URL?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private let expiries: [(String, TimeInterval?)] = [("Never", nil), ("1 hour", 3600), ("1 day", 86_400), ("7 days", 604_800),
                                                       ("30 days", 2_592_000), ("1 year", 31_536_000)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(albumID == nil ? "Share \(assetIDs.count) Item\(assetIDs.count == 1 ? "" : "s") by Link" : "Share Album by Link").font(.headline)
            if let created {
                HStack {
                    Text(created.absoluteString).textSelection(.enabled).font(.callout.monospaced()).lineLimit(2)
                        .accessibilityIdentifier("shared-link-url")
                    Button("Copy") { copy(created) }
                }
                Text("Anyone with the link can view\(options.password.isEmpty ? "" : " after entering the password").")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Form {
                    TextField("Description", text: $options.description)
                    Picker("Expires", selection: $expiry) { ForEach(expiries.indices, id: \.self) { Text(expiries[$0].0).tag($0) } }
                    SecureField("Password (optional)", text: $options.password)
                    Toggle("Allow downloads", isOn: $options.allowDownload)
                    Toggle("Show metadata", isOn: $options.showMetadata)
                    if albumID != nil { Toggle("Allow uploads", isOn: $options.allowUpload) }
                }
                .formStyle(.grouped).frame(width: 420)
            }
            if let error { Text(error).foregroundStyle(Theme.danger).font(.caption) }
            HStack {
                Spacer()
                if created == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Create Link", action: create).keyboardShortcut(.defaultAction).accessibilityIdentifier("create-link")
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
    }

    private func create() {
        options.expiresIn = expiries[expiry].1
        let options = options
        Task {
            do {
                let link = try await library.albumActions.createLink(albumID: albumID, assetIDs: assetIDs, options: options)
                let url = await library.albumActions.url(for: link)
                created = url
                copy(url)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        library.flash("Link copied")
    }
}

// MARK: Sharing (partners and links)

struct SharingView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var sharedWithMe: [PartnerResponseDto] = []
    @State private var sharedByMe: [PartnerResponseDto] = []
    @State private var links: [SharedLinkResponseDto] = []
    @State private var users: [UserResponseDto] = []
    @State private var linkURLs: [String: URL] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                group("Partners sharing with you") {
                    if sharedWithMe.isEmpty { Text("Nobody shares their library with you yet.").foregroundStyle(Theme.textTertiary) }
                    ForEach(sharedWithMe, id: \.id) { partner in
                        HStack {
                            Button(partner.name) {
                                library.partnerNames[partner.id] = partner.name
                                library.destination = .partner(partner.id)
                            }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("partner-\(partner.email)")
                            Text(partner.email).font(.caption).foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Toggle("Show in my Photos", isOn: Binding(get: { partner.inTimeline ?? false },
                                                                      set: { value in setInTimeline(partner, value) }))
                        }
                    }
                }
                group("Your library is shared with") {
                    ForEach(sharedByMe, id: \.id) { partner in
                        HStack {
                            Text(partner.name)
                            Text(partner.email).font(.caption).foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Button("Stop Sharing") { remove(partner) }
                        }
                    }
                    Menu("Share My Library With…") {
                        ForEach(users.filter { u in u.id != library.session.account.userID && !sharedByMe.contains { $0.id == u.id } }, id: \.id) { user in
                            Button("\(user.name) (\(user.email))") { addPartner(user) }
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("add-partner")
                }
                group("Shared links") {
                    if links.isEmpty { Text("No shared links").foregroundStyle(Theme.textTertiary) }
                    ForEach(links, id: \.id) { link in
                        HStack {
                            Image(systemName: link.type == .album ? "rectangle.stack" : "photo")
                            VStack(alignment: .leading) {
                                Text(link.album?.albumName ?? link.description ?? "\(link.assets.count) item\(link.assets.count == 1 ? "" : "s")")
                                Text(linkDetails(link)).font(.caption).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            if let url = linkURLs[link.id] {
                                Button("Copy Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    library.flash("Link copied")
                                }
                            }
                            Button("Delete") { deleteLink(link) }
                        }
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.gridBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharing")
        .task { await load() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.medium)).foregroundStyle(Theme.text)
            content()
        }
    }

    private func linkDetails(_ link: SharedLinkResponseDto) -> String {
        var parts: [String] = []
        if let expires = link.expiresAt.flatMap(ImmichDate.parse) {
            parts.append(expires < .now ? "Expired" : "Expires \(expires.formatted(date: .abbreviated, time: .omitted))")
        } else { parts.append("Never expires") }
        if link.password != nil { parts.append("Password") }
        if link.allowDownload { parts.append("Downloads allowed") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        if let partners = try? await library.albumActions.partners() {
            sharedWithMe = partners.sharedWithMe
            sharedByMe = partners.sharedByMe
            for p in sharedWithMe { library.partnerNames[p.id] = p.name }
        }
        links = (try? await library.client.getAllSharedLinks()) ?? []
        users = (try? await library.client.searchUsers()) ?? []
        for link in links { linkURLs[link.id] = await library.albumActions.url(for: link) }
    }

    private func setInTimeline(_ partner: PartnerResponseDto, _ value: Bool) {
        Task { _ = try? await library.client.updatePartner(id: partner.id, body: PartnerUpdateDto(inTimeline: value)); await load() }
    }

    private func addPartner(_ user: UserResponseDto) {
        Task { _ = try? await library.client.createPartner(body: PartnerCreateDto(sharedWithId: user.id)); await load() }
    }

    private func remove(_ partner: PartnerResponseDto) {
        Task { try? await library.client.removePartner(id: partner.id); await load() }
    }

    private func deleteLink(_ link: SharedLinkResponseDto) {
        Task { try? await library.client.removeSharedLink(id: link.id); await load() }
    }
}
