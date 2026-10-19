import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

/// Sheets the library can present.
enum LibrarySheet: Identifiable {
    case dateTime([String])
    case metadata([String])
    case albumPicker([String])
    case newAlbum([String])
    case tags([String])
    case geotag([String])
    case confirmEmptyTrash(Int)
    case editAlbum(String)
    case shareAlbum(String)
    case sharedLink(albumID: String?, assetIDs: [String])

    var id: String {
        switch self {
        case .dateTime: "date"
        case .metadata: "metadata"
        case .albumPicker: "albumPicker"
        case .newAlbum: "newAlbum"
        case .tags: "tags"
        case .geotag: "geotag"
        case .confirmEmptyTrash: "emptyTrash"
        case .editAlbum: "editAlbum"
        case .shareAlbum: "shareAlbum"
        case .sharedLink: "sharedLink"
        }
    }
}

/// One menu item, rendered as an NSMenu (grid right-click) or SwiftUI (loupe, menu bar).
struct MenuEntry: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String?
    var key: KeyEquivalent?
    var modifiers: EventModifiers = []
    var isEnabled = true
    var isChecked = false
    var children: [MenuEntry] = []
    var action: (() -> Void)?
    var isSeparator = false

    static var separator: MenuEntry { MenuEntry(title: "", isSeparator: true) }

    /// Plain-letter shortcuts are handled by the library's key monitor, not as menu key equivalents
    /// (so typing in text fields is never hijacked).
    var isPlainKey: Bool { key != nil && modifiers.subtracting(.shift).isEmpty }
}

extension LibraryModel {
    var actions: AssetActions { AssetActions(client: client) }

    /// What actions apply to: the selection in the grid, or the photo shown in the loupe.
    var targetIDs: [String] {
        if mode != .grid, let focusedAssetID { return [focusedAssetID] }
        let order = orderedAssets.map(\.id)
        let selected = selection
        let ordered = order.filter { selected.contains($0) }
        return ordered.isEmpty ? Array(selected) : ordered
    }

    var targetAssets: [TimelineAsset] { targetIDs.compactMap { timeline.asset($0) } }

    // MARK: Running actions with undo

    /// Runs an action, applies its effect locally, and registers ⌘Z / ⇧⌘Z.
    func perform(_ label: String, ids: [String], change: AssetChange?, rewritesFiles: Bool = false,
                 _ operation: @escaping @Sendable (AssetActions) async throws -> UndoAction) {
        guard !ids.isEmpty else { return }
        let actions = self.actions
        Task {
            do {
                let undo = try await operation(actions)
                apply(change)
                if rewritesFiles { rewrites.schedule(ids) }
                registerUndo(undo, redo: (label, ids, change, operation), rewritesFiles: rewritesFiles)
                flash("\(label): \(ids.count == 1 ? "1 item" : "\(ids.count) items")")
            } catch {
                flash("\(label) failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func registerUndo(_ undo: UndoAction,
                              redo: (String, [String], AssetChange?, @Sendable (AssetActions) async throws -> UndoAction),
                              rewritesFiles: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            Task { @MainActor in
                do {
                    // If the change was already written into the files, swap the old files back first.
                    if rewritesFiles { for id in redo.1 { _ = await model.rewrites.revert(id) } }
                    try await undo.run()
                    await model.refreshAfterUndo(ids: redo.1)
                    model.flash("Undo \(undo.name)")
                } catch {
                    model.flash("Couldn’t undo \(undo.name): \(error.localizedDescription)", isError: true)
                }
            }
            // Redo runs the original action again.
            model.undoManager?.registerUndo(withTarget: model) { model in
                model.perform(redo.0, ids: redo.1, change: redo.2, rewritesFiles: rewritesFiles, redo.3)
            }
            model.undoManager?.setActionName(undo.name)
        }
        undoManager.setActionName(undo.name)
    }

    func refreshAfterUndo(ids: [String]) async {
        detailsRevision += 1
        await timeline.reload()
        await timeline.refresh(assetIDs: Set(ids))
    }

    /// Updates the current grid immediately (Immich's live events follow).
    func apply(_ change: AssetChange?) {
        guard let change else { return }
        detailsRevision += 1
        switch change {
        case .favorite(let ids, let value):
            for id in ids { timeline.update(id) { $0.isFavorite = value } }
            if destination == .favorites, !value { timeline.remove(Set(ids)) }
        case .visibility(let ids, let visibility):
            let staysVisible: Bool = switch destination {
            case .archive: visibility == .archive
            case .locked: visibility == .locked
            case .photos, .favorites: visibility == .timeline
            default: true
            }
            if staysVisible { for id in ids { timeline.update(id) { $0.visibility = visibility } } }
            else { removeFromView(ids) }
        case .trashed(let ids):
            if destination != .trash { removeFromView(ids) }
        case .restored(let ids):
            if destination == .trash { removeFromView(ids) }
        case .metadata(let ids), .albums(let ids), .stacked(let ids):
            Task { await timeline.refresh(assetIDs: Set(ids)) }
        }
    }

    private func removeFromView(_ ids: [String]) {
        if mode != .grid, let focused = focusedAssetID, ids.contains(focused) {
            step(1)
            if focusedAssetID == focused { step(-1) }
            if focusedAssetID == focused { mode = .grid }
        }
        selection.subtract(ids)
        timeline.remove(Set(ids))
    }

    func flash(_ message: String, isError: Bool = false) {
        statusMessage = message
        let current = message
        Task {
            try? await Task.sleep(for: .seconds(isError ? 8 : 3))
            if statusMessage == current { statusMessage = nil }
        }
    }

    // MARK: Individual actions

    func toggleFavorite() {
        let ids = targetIDs
        let value = !(targetAssets.allSatisfy(\.isFavorite))
        perform(value ? "Favorite" : "Unfavorite", ids: ids, change: .favorite(ids: ids, value)) { try await $0.setFavorite(ids, value) }
    }

    func setRating(_ rating: Int) {
        let ids = targetIDs
        perform(rating == 0 ? "Clear Rating" : "Rate \(rating)★", ids: ids, change: .metadata(ids: ids), rewritesFiles: true) { try await $0.setRating(ids, rating) }
    }

    func setVisibility(_ visibility: AssetVisibility) {
        let ids = targetIDs
        let label = switch visibility {
        case .archive: "Archive"
        case .locked: "Move to Locked Folder"
        default: "Unarchive"
        }
        perform(label, ids: ids, change: .visibility(ids: ids, visibility)) { try await $0.setVisibility(ids, visibility) }
    }

    func trashSelection() {
        let ids = targetIDs
        perform("Move to Trash", ids: ids, change: .trashed(ids: ids)) { try await $0.trash(ids) }
    }

    func restoreSelection() {
        let ids = targetIDs
        perform("Restore", ids: ids, change: .restored(ids: ids)) { try await $0.restore(ids) }
    }

    func removeFromCurrentAlbum() {
        guard case .album(let albumID) = destination else { return }
        let ids = targetIDs
        perform("Remove from Album", ids: ids, change: .trashed(ids: ids)) { try await $0.removeFromAlbum(albumID, ids) }
    }

    func addToAlbum(_ album: AlbumResponseDto) {
        let ids = targetIDs
        recentAlbumIDs.removeAll { $0 == album.id }
        recentAlbumIDs.insert(album.id, at: 0)
        perform("Add to “\(album.albumName)”", ids: ids, change: .albums(ids: ids)) { try await $0.addToAlbum(album.id, ids) }
    }

    func stackSelection() {
        let ids = targetIDs
        guard ids.count >= 2 else { return }
        perform("Stack", ids: ids, change: .stacked(ids: ids)) { actions in
            let (_, undo) = try await actions.stack(ids)
            return undo
        }
        Task { try? await Task.sleep(for: .seconds(1)); await timeline.reload() }
    }

    func unstackSelection() {
        let stacks = Set(targetAssets.compactMap(\.stackID))
        let ids = targetIDs
        for stackID in stacks {
            perform("Unstack", ids: ids, change: .stacked(ids: ids)) { try await $0.unstack(stackID: stackID) }
        }
        Task { try? await Task.sleep(for: .seconds(1)); await timeline.reload() }
    }

    func copyLocation() {
        guard let asset = targetAssets.first else { return }
        Task {
            guard let info = try? await client.getAssetInfo(id: asset.id),
                  let lat = info.exifInfo?.latitude, let lon = info.exifInfo?.longitude else {
                flash("This photo has no location", isError: true)
                return
            }
            copiedLocation = CLLocationCoordinate2DBox(latitude: lat, longitude: lon)
            flash("Copied location")
        }
    }

    func pasteLocation() {
        guard let location = copiedLocation else { return }
        setLocation(latitude: location.latitude, longitude: location.longitude)
    }

    func setLocation(latitude: Double, longitude: Double, ids: [String]? = nil) {
        let ids = ids ?? targetIDs
        perform("Set Location", ids: ids, change: .metadata(ids: ids), rewritesFiles: true) { try await $0.setLocation(ids, latitude: latitude, longitude: longitude) }
    }

    func emptyTrash() {
        Task {
            do {
                let count = try await actions.emptyTrash()
                await timeline.reload()
                flash("Deleted \(count) item\(count == 1 ? "" : "s") permanently")
            } catch {
                flash("Empty Trash failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func restoreAllTrash() {
        Task {
            do {
                let result = try await client.restoreTrash()
                await timeline.reload()
                flash("Restored \(result.count) item\(result.count == 1 ? "" : "s")")
            } catch {
                flash("Restore failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    /// Downloads originals: one file via a save panel, several into a chosen folder.
    func downloadOriginals() {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        Task {
            guard let details = try? await actions.details(ids), !details.isEmpty else { return }
            var destinations: [(AssetResponseDto, URL)] = []
            if details.count == 1, let asset = details.first {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = asset.originalFileName
                guard panel.runModal() == .OK, let url = panel.url else { return }
                destinations = [(asset, url)]
            } else {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Download \(details.count) Originals"
                guard panel.runModal() == .OK, let folder = panel.url else { return }
                var used = Set<String>()
                for asset in details {
                    var name = asset.originalFileName
                    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                    var n = 2
                    while used.contains(name.lowercased()) || FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
                        name = "\(base) (\(n)).\(ext)"; n += 1
                    }
                    used.insert(name.lowercased())
                    destinations.append((asset, folder.appending(path: name)))
                }
            }
            var done = 0
            for (asset, url) in destinations {
                statusMessage = "Downloading \(done + 1) of \(destinations.count)…"
                do {
                    _ = try await client.downloadOriginal(assetID: asset.id, to: url)
                    done += 1
                } catch {
                    flash("Download of \(asset.originalFileName) failed: \(error.localizedDescription)", isError: true)
                }
            }
            flash("Downloaded \(done) original\(done == 1 ? "" : "s")")
            if let first = destinations.first?.1 { NSWorkspace.shared.activateFileViewerSelecting([first]) }
        }
    }

    // MARK: The shared menu

    func assetMenu(includeOpen: Bool) -> [MenuEntry] {
        let ids = targetIDs
        let assets = targetAssets
        let has = !ids.isEmpty
        if destination == .trash {
            return [
                MenuEntry(title: "Restore", symbol: "arrow.uturn.backward", key: "r", modifiers: .command, isEnabled: has) { [weak self] in self?.restoreSelection() },
                .separator,
                MenuEntry(title: "Download Original…", symbol: "arrow.down.circle", key: "d", modifiers: [.command, .option], isEnabled: has) { [weak self] in self?.downloadOriginals() },
            ]
        }
        let allFavorite = has && assets.allSatisfy(\.isFavorite)
        let visibility = assets.first?.visibility
        var entries: [MenuEntry] = []
        if includeOpen {
            entries.append(MenuEntry(title: "Open", symbol: "rectangle", key: "e", isEnabled: has) { [weak self] in
                if let self, let id = ids.first { self.open(id) }
            })
            entries.append(.separator)
        }
        entries.append(MenuEntry(title: allFavorite ? "Unfavorite" : "Favorite", symbol: allFavorite ? "heart.slash" : "heart",
                                 key: "h", isEnabled: has) { [weak self] in self?.toggleFavorite() })
        entries.append(MenuEntry(title: "Rating", symbol: "star", isEnabled: has, children:
            (0...5).map { stars in
                MenuEntry(title: stars == 0 ? "None" : String(repeating: "★", count: stars),
                          key: KeyEquivalent(Character(String(stars)))) { [weak self] in self?.setRating(stars) }
            }))
        if destination != .trash { entries.append(presetMenu()) }
        var albumItems: [MenuEntry] = [
            MenuEntry(title: "New Album…", symbol: "plus") { [weak self] in self?.sheet = .newAlbum(ids) },
            MenuEntry(title: "Choose Album…", key: "a", modifiers: [.command, .shift]) { [weak self] in self?.sheet = .albumPicker(ids) },
        ]
        let recent = recentAlbumIDs.compactMap { id in albums.first { $0.id == id } }.prefix(8)
        if !recent.isEmpty {
            albumItems.append(.separator)
            albumItems += recent.map { album in MenuEntry(title: album.albumName) { [weak self] in self?.addToAlbum(album) } }
        }
        entries.append(MenuEntry(title: "Add to Album", symbol: "rectangle.stack.badge.plus", isEnabled: has, children: albumItems))
        entries.append(MenuEntry(title: "Add Tags…", symbol: "tag", key: "t", modifiers: [.command, .shift], isEnabled: has) { [weak self] in
            self?.sheet = .tags(ids)
        })
        if case .album = destination {
            entries.append(MenuEntry(title: "Remove from Album", symbol: "rectangle.stack.badge.minus", isEnabled: has) { [weak self] in
                self?.removeFromCurrentAlbum()
            })
            if let album = currentAlbum, isOwner(album) {
                entries.append(MenuEntry(title: "Set as Album Cover", symbol: "photo.badge.checkmark", isEnabled: ids.count == 1) { [weak self] in
                    self?.setAlbumCover()
                })
            }
        }
        entries.append(MenuEntry(title: "Share by Link…", symbol: "link", isEnabled: has) { [weak self] in
            self?.sheet = .sharedLink(albumID: nil, assetIDs: ids)
        })
        entries.append(.separator)
        entries.append(MenuEntry(title: "Rotate Left", symbol: "rotate.left", key: .leftArrow, modifiers: [.command, .option], isEnabled: has) { [weak self] in
            self?.rotateSelection(-1)
        })
        entries.append(MenuEntry(title: "Rotate Right", symbol: "rotate.right", key: .rightArrow, modifiers: [.command, .option], isEnabled: has) { [weak self] in
            self?.rotateSelection(1)
        })
        if assets.contains(where: \.isLivePhoto) {
            entries.append(MenuEntry(title: "Make Still", symbol: "livephoto.slash", key: "m", modifiers: [.command, .shift, .option]) { [weak self] in
                self?.makeStill()
            })
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Adjust Date & Time…", symbol: "calendar.badge.clock", key: "d", modifiers: [.command, .shift],
                                 isEnabled: has) { [weak self] in self?.sheet = .dateTime(ids) })
        entries.append(MenuEntry(title: "Edit Metadata…", symbol: "pencil", key: "m", modifiers: [.command, .shift],
                                 isEnabled: has) { [weak self] in self?.sheet = .metadata(ids) })
        entries.append(MenuEntry(title: "Location", symbol: "mappin.and.ellipse", isEnabled: has, children: [
            MenuEntry(title: "Set on Map…", key: "l", modifiers: [.command, .shift]) { [weak self] in self?.sheet = .geotag(ids) },
            MenuEntry(title: "Copy Location", key: "c", modifiers: [.command, .option], isEnabled: ids.count == 1) { [weak self] in self?.copyLocation() },
            MenuEntry(title: "Paste Location", key: "v", modifiers: [.command, .option], isEnabled: copiedLocation != nil) { [weak self] in self?.pasteLocation() },
        ]))
        if ids.count >= 2 {
            entries.append(MenuEntry(title: "Stack", symbol: "square.stack", key: "g", modifiers: .command) { [weak self] in self?.stackSelection() })
            entries.append(MenuEntry(title: "Merge to HDR…", symbol: "camera.aperture", key: "h", modifiers: .control) { [weak self] in
                self?.startMerge(.hdr)
            })
            entries.append(MenuEntry(title: "Merge to Panorama…", symbol: "pano", key: "m", modifiers: .control) { [weak self] in
                self?.startMerge(.panorama(.perspective))
            })
        }
        if assets.contains(where: { $0.stackID != nil }) {
            entries.append(MenuEntry(title: "Unstack", symbol: "square.stack.3d.down.right", key: "g", modifiers: [.command, .shift]) { [weak self] in
                self?.unstackSelection()
            })
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Download Original…", symbol: "arrow.down.circle", key: "d", modifiers: [.command, .option],
                                 isEnabled: has) { [weak self] in self?.downloadOriginals() })
        if visibility == .archive {
            entries.append(MenuEntry(title: "Unarchive", symbol: "archivebox", key: "a", modifiers: [.command, .option], isEnabled: has) { [weak self] in
                self?.setVisibility(.timeline)
            })
        } else if visibility == .locked {
            entries.append(MenuEntry(title: "Remove from Locked Folder", symbol: "lock.open", isEnabled: has) { [weak self] in
                self?.setVisibility(.timeline)
            })
        } else {
            entries.append(MenuEntry(title: "Archive", symbol: "archivebox", key: "a", modifiers: [.command, .option], isEnabled: has) { [weak self] in
                self?.setVisibility(.archive)
            })
            entries.append(MenuEntry(title: "Move to Locked Folder", symbol: "lock", isEnabled: has) { [weak self] in
                self?.setVisibility(.locked)
            })
        }
        entries.append(.separator)
        entries.append(MenuEntry(title: "Move to Trash", symbol: "trash", key: .delete, modifiers: .command, isEnabled: has) { [weak self] in
            self?.trashSelection()
        })
        return entries
    }
}

/// Sendable copy of a coordinate (for Copy / Paste Location).
struct CLLocationCoordinate2DBox: Equatable {
    var latitude: Double
    var longitude: Double
}

// MARK: Rendering MenuEntry

extension MenuEntry {
    func nsMenuItem() -> NSMenuItem {
        if isSeparator { return .separator() }
        let item = ClosureMenuItem(title: title, action: action)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.isEnabled = isEnabled
        item.state = isChecked ? .on : .off
        if let key {
            switch key {
            case .delete: item.keyEquivalent = "\u{8}"
            case .leftArrow: item.keyEquivalent = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .rightArrow: item.keyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            default: item.keyEquivalent = String(key.character)
            }
            var mask: NSEvent.ModifierFlags = []
            if modifiers.contains(.command) { mask.insert(.command) }
            if modifiers.contains(.shift) { mask.insert(.shift) }
            if modifiers.contains(.option) { mask.insert(.option) }
            if modifiers.contains(.control) { mask.insert(.control) }
            item.keyEquivalentModifierMask = mask
        }
        if !children.isEmpty {
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            children.forEach { submenu.addItem($0.nsMenuItem()) }
            item.submenu = submenu
        }
        return item
    }

    static func nsMenu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        entries.forEach { menu.addItem($0.nsMenuItem()) }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(title: String, action handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?() }
}

/// SwiftUI rendering for the loupe's context menu and the Photo menu.
struct MenuEntriesView: View {
    let entries: [MenuEntry]
    /// Menu-bar items get key equivalents (except plain keys, which the key monitor handles).
    var bindShortcuts = false

    var body: some View {
        ForEach(entries) { entry in
            if entry.isSeparator {
                Divider()
            } else if !entry.children.isEmpty {
                Menu {
                    MenuEntriesView(entries: entry.children, bindShortcuts: bindShortcuts)
                } label: {
                    label(entry)
                }
                .disabled(!entry.isEnabled)
            } else {
                button(entry)
            }
        }
    }

    @ViewBuilder private func button(_ entry: MenuEntry) -> some View {
        let base = Button { entry.action?() } label: { label(entry) }.disabled(!entry.isEnabled)
        if bindShortcuts, let key = entry.key, !entry.isPlainKey {
            base.keyboardShortcut(key, modifiers: entry.modifiers)
        } else {
            base
        }
    }

    @ViewBuilder private func label(_ entry: MenuEntry) -> some View {
        if let symbol = entry.symbol { Label(entry.title, systemImage: symbol) } else { Text(entry.title) }
    }
}
