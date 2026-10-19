import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

/// "Edit in…" companion-app sessions: open in another editor, detect when it's closed, upload the result as
/// the Mac version (stacked on the original, original hidden — same as Develop versions).
@MainActor
final class EditInModel: ObservableObject {
    @Published private(set) var editors: [CompanionEditor] = []
    @Published private(set) var sessions: [EditSession] = []
    @Published private(set) var busy: Set<UUID> = []
    @AppStorage("editorRAW", store: .darkRoom) var rawEditor = ""
    @AppStorage("editorImage", store: .darkRoom) var imageEditor = ""
    @AppStorage("keepEditableFiles", store: .darkRoom) var keepEditableDefault = false
    @AppStorage("askedAccessibility", store: .darkRoom) private var askedAccessibility = false

    private unowned let library: LibraryModel
    private var poller: Task<Void, Never>?
    let root: URL
    let keptRoot: URL

    init(library: LibraryModel) {
        self.library = library
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DarkRoom/\(library.session.account.id.uuidString)")
        root = base.appending(path: "Edits")
        keptRoot = base.appending(path: "Kept Edits")
        refreshEditors()
    }

    func refreshEditors() { editors = CompanionEditor.installed() }

    func defaultEditor(forName name: String) -> CompanionEditor? {
        CompanionEditor.defaultEditor(for: URL(fileURLWithPath: "/x/\(name)"), among: editors,
                                      preferences: ["raw": rawEditor, "image": imageEditor].filter { !$0.value.isEmpty })
    }

    /// Opens the targeted photos in `editor` (or each photo's default editor).
    func edit(_ ids: [String], in editor: CompanionEditor?) {
        let develop = library.develop
        // Ask for Accessibility (to notice when the photo's window closes) once; never during UI tests.
        if !askedAccessibility, ProcessInfo.processInfo.environment["DARKROOM_DATA_DIR"] == nil {
            askedAccessibility = true
            _ = EditSession.requestAccessibility()
        }
        Task {
            for id in ids {
                do {
                    let context = try await develop.versions.context(for: id)
                    guard context.original.ownerId == library.session.account.userID else {
                        library.flash("Only your own photos can be edited", isError: true); continue
                    }
                    guard context.original.type == .image else { library.flash("Videos can only be rotated", isError: true); continue }
                    guard let chosen = editor ?? defaultEditor(forName: context.original.originalFileName) else {
                        library.flash("No photo editor found on this Mac", isError: true); return
                    }
                    library.statusMessage = "Opening \(context.original.originalFileName) in \(chosen.name)…"
                    let file = try await develop.originals.file(for: context.original)
                    let session = try EditSession.start(assetID: context.original.id, assetName: context.original.originalFileName,
                                                        original: file, editor: chosen, root: root, keepEditable: keepEditableDefault)
                    sessions.append(session)
                    library.flash(chosen.returns == .watchedExport
                                  ? "Export from \(chosen.name) into the folder shown in Finder; DarkRoom uploads it"
                                  : "Editing in \(chosen.name): save and close the photo when you’re done")
                } catch {
                    library.flash("Couldn’t open in editor: \(error.localizedDescription)", isError: true)
                }
            }
            startPolling()
        }
    }

    private func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while let self, !self.sessions.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                for session in self.sessions where !self.busy.contains(session.id) {
                    switch session.editor.returns {
                    case .watchedExport:
                        if (try? session.result()) != nil { await self.finish(session) }
                    default:
                        if !session.isStillOpen() { await self.finish(session) }
                    }
                }
            }
            self?.poller = nil
        }
    }

    /// Uploads the result as the Mac version (or ends quietly if nothing was saved).
    func finish(_ session: EditSession) async {
        busy.insert(session.id)
        defer { busy.remove(session.id) }
        let develop = library.develop
        do {
            library.statusMessage = "Collecting the edit from \(session.editor.name)…"
            let resultFile = try await Task.detached { try session.result() }.value
            guard let resultFile else {
                library.flash("No changes saved in \(session.editor.name) for \(session.assetName)")
                close(session)
                return
            }
            library.statusMessage = "Uploading \(session.assetName)…"
            let context = try await develop.versions.context(for: session.assetID)
            let original = try await develop.originals.file(for: context.original)
            _ = try await develop.versions.saveExternal(resultFile, context: context, originalFile: original, editor: session.editor.name)
            if session.keepEditable { keep(session) }
            close(session)
            library.flash("Saved \(session.assetName) from \(session.editor.name)")
            await library.timeline.reload()
            library.detailsRevision += 1
        } catch {
            library.flash("Couldn’t save the edit: \(error.localizedDescription)", isError: true)
        }
    }

    func cancel(_ session: EditSession) { close(session) }

    private func close(_ session: EditSession) {
        sessions.removeAll { $0.id == session.id }
        if !session.keepEditable { try? FileManager.default.removeItem(at: session.folder) }
    }

    /// Moves layered / project files to Kept Edits (on this Mac only).
    private func keep(_ session: EditSession) {
        let destination = keptRoot.appending(path: session.assetName.replacingOccurrences(of: "/", with: "-") + " (\(session.editor.name))")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in session.editableFiles() {
            try? FileManager.default.moveItem(at: file, to: destination.appending(path: file.lastPathComponent))
        }
        try? FileManager.default.removeItem(at: session.folder)
    }

    func setKeep(_ session: EditSession, _ value: Bool) {
        session.keepEditable = value
        objectWillChange.send()
    }

    var keptEdits: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: keptRoot, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

extension LibraryModel {
    func editInMenu() -> MenuEntry {
        let ids = targetIDs
        let model = editIn
        var children = model.editors.map { editor in
            MenuEntry(title: editor.name) { [weak self] in self?.editIn.edit(ids, in: editor) }
        }
        if children.isEmpty { children = [MenuEntry(title: "No editors found", isEnabled: false)] }
        children.append(.separator)
        children.append(MenuEntry(title: "Refresh Editor List") { [weak self] in self?.editIn.refreshEditors() })
        return MenuEntry(title: "Edit in", symbol: "arrow.up.forward.app", isEnabled: !ids.isEmpty, children: children)
    }
}

/// Active "Edit in" sessions under the content area.
struct EditSessionsBar: View {
    @ObservedObject var model: EditInModel

    var body: some View {
        if !model.sessions.isEmpty {
            VStack(spacing: 4) {
                ForEach(model.sessions) { session in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.forward.app").foregroundStyle(Theme.highlight)
                        Text("Editing \(session.assetName) in \(session.editor.name)").lineLimit(1)
                        if session.editor.returns == .watchedExport {
                            Button("Show Export Folder") { NSWorkspace.shared.activateFileViewerSelecting([session.exportFolder]) }
                                .buttonStyle(.link)
                        }
                        Spacer()
                        Toggle("Keep editable file", isOn: Binding(get: { session.keepEditable }, set: { model.setKeep(session, $0) }))
                            .toggleStyle(.checkbox)
                        if model.busy.contains(session.id) { ProgressView().controlSize(.small) }
                        Button("Done Editing") { Task { await model.finish(session) } }.accessibilityIdentifier("edit-in-done")
                        Button("Cancel") { model.cancel(session) }.accessibilityIdentifier("edit-in-cancel")
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.panelRaised)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("edit-sessions")
        }
    }
}
