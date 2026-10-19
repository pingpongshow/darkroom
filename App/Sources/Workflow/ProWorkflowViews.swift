import SwiftUI
import AppKit
import Quartz
import ImmichAPI
import DarkRoomCore

// MARK: Culling

extension LibraryModel {
    /// P / X / U (Lightroom flags), stored as the Immich tags Culling/Pick and Culling/Reject.
    func setFlag(_ flag: CullFlag?) {
        let ids = targetIDs
        let culling = Culling(client: client)
        perform(flag == .pick ? "Pick" : (flag == .reject ? "Reject" : "Unflag"), ids: ids, change: .metadata(ids: ids)) { _ in
            try await culling.setFlag(flag, on: ids)
        }
        if autoAdvance && mode != .grid { step(1) }
    }

    /// Trash every rejected photo (with confirmation in the UI).
    func trashRejects() {
        Task {
            do {
                let rejects = try await Culling(client: client).assets(flagged: .reject).map(\.id)
                guard !rejects.isEmpty else { flash("No rejected photos"); return }
                perform("Move Rejects to Trash", ids: rejects, change: .trashed(ids: rejects)) { try await $0.trash(rejects) }
            } catch { flash("Couldn’t find rejects: \(error.localizedDescription)", isError: true) }
        }
    }
}

/// Filter bar (Lightroom's Library filter): rating, flag, type. Builds a search over the current view.
struct FilterBar: View {
    @EnvironmentObject var library: LibraryModel
    @State private var rating = 0
    @State private var flag = 0          // 0 any, 1 picks, 2 rejects
    @State private var type = SearchQuery.MediaType.all

    var body: some View {
        HStack(spacing: 12) {
            Text("Filter").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Picker("Rating", selection: $rating) {
                Text("Any rating").tag(0)
                ForEach(1...5, id: \.self) { Text("≥ " + String(repeating: "★", count: $0)).tag($0) }
            }.fixedSize()
            Picker("Flag", selection: $flag) { Text("Any flag").tag(0); Text("Picks").tag(1); Text("Rejects").tag(2) }.fixedSize()
            Picker("Type", selection: $type) {
                Text("All types").tag(SearchQuery.MediaType.all); Text("Photos").tag(SearchQuery.MediaType.photos); Text("Videos").tag(SearchQuery.MediaType.videos)
            }.fixedSize()
            Button("Apply") { apply() }.accessibilityIdentifier("filter-apply")
            Spacer()
            Toggle("Auto advance", isOn: $library.autoAdvance).toggleStyle(.checkbox).help("Move to the next photo after rating or flagging")
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter-bar")
    }

    private func apply() {
        var query = SearchQuery()
        switch library.destination {
        case .album(let id): query.albumIDs = [id]
        case .person(let id): query.personIDs = [id]
        case .tag(let id): query.tagIDs = [id]
        case .favorites: query.favoritesOnly = true
        case .archive: query.includeArchived = true
        default: break
        }
        query.minimumRating = rating == 0 ? nil : rating
        query.mediaType = type
        Task {
            if flag != 0, let tag = try? await Culling(client: library.client).tagIDs()[flag == 1 ? .pick : .reject] {
                query.tagIDs.append(tag)
            }
            library.search(query)
        }
    }
}

// MARK: Compare (C) and Survey (N)

struct CompareView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        let assets = Array(library.targetAssets.prefix(4))
        VStack(spacing: 0) {
            if assets.count < 2 {
                Text("Select 2–4 photos to compare (C).").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let columns = assets.count == 2 ? 2 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                    ForEach(assets) { asset in
                        GeometryReader { geo in
                            PipelineImage(asset: asset, size: .preview, maxPixel: 2048).scaledToFit()
                                .scaleEffect(zoom).offset(offset)
                                .frame(width: geo.size.width, height: geo.size.height).clipped()
                                .overlay(alignment: .bottomLeading) {
                                    HStack(spacing: 6) {
                                        Button { library.focusedAssetID = asset.id; library.selection = [asset.id]; library.setFlag(.pick) } label: { Image(systemName: "flag.fill") }
                                        Button { library.focusedAssetID = asset.id; library.selection = [asset.id]; library.setFlag(.reject) } label: { Image(systemName: "xmark") }
                                    }
                                    .buttonStyle(.borderless).foregroundStyle(.white).padding(8)
                                }
                        }
                        .frame(height: assets.count == 2 ? 600 : 300)
                    }
                }
                // Synchronised zoom and pan for every panel.
                .gesture(MagnifyGesture().onChanged { zoom = max(1, min(8, $0.magnification)) })
                .simultaneousGesture(DragGesture().onChanged { offset = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }
                    .onEnded { _ in dragStart = offset })
                .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2; offset = .zero; dragStart = .zero }
            }
        }
        .background(Theme.gridBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compare-view")
    }
}

struct SurveyView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var removed: Set<String> = []

    var body: some View {
        let assets = library.targetAssets.filter { !removed.contains($0.id) }
        GeometryReader { geo in
            let n = max(1, assets.count)
            let cols = Int(ceil(sqrt(Double(n) * geo.size.width / max(1, geo.size.height))))
            let rows = Int(ceil(Double(n) / Double(max(1, cols))))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: max(1, cols)), spacing: 6) {
                ForEach(assets) { asset in
                    PipelineImage(asset: asset, size: .preview, maxPixel: 1200).scaledToFit()
                        .frame(height: geo.size.height / CGFloat(max(1, rows)) - 8)
                        .overlay(alignment: .topTrailing) {
                            Button { removed.insert(asset.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.white).padding(6).help("Remove from survey")
                        }
                }
            }
            .padding(6)
        }
        .background(Theme.gridBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("survey-view")
    }
}

// MARK: Export (⇧⌘E)

@MainActor
final class ExportPresetsStore: ObservableObject {
    @AppStorage("exportPresets", store: .darkRoom) private var raw = ""
    var presets: [ExportSettings] {
        get { (try? JSONDecoder().decode([ExportSettings].self, from: Data(raw.utf8))) ?? [ExportSettings()] }
        set { raw = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data(), as: UTF8.self); objectWillChange.send() }
    }
}

struct ExportSheet: View {
    @EnvironmentObject var library: LibraryModel
    let ids: [String]
    @StateObject private var store = ExportPresetsStore()
    @State private var settings = ExportSettings()
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export \(ids.count) Item\(ids.count == 1 ? "" : "s")").font(.headline)
            HStack {
                Picker("Preset", selection: Binding(get: { settings.name }, set: { name in
                    if let p = store.presets.first(where: { $0.name == name }) { settings = p }
                })) { ForEach(store.presets, id: \.name) { Text($0.name).tag($0.name) } }
                Button("Save Preset") {
                    var all = store.presets.filter { $0.name != settings.name }
                    all.append(settings); store.presets = all
                }
            }
            Form {
                Picker("Format", selection: $settings.format) { ForEach(ExportSettings.Format.allCases, id: \.self) { Text($0.rawValue) } }
                    .accessibilityIdentifier("export-format")
                Toggle("Edited version", isOn: $settings.edited)
                TextField("Long edge (pixels, blank = full size)", value: $settings.longEdge, format: .number)
                if settings.format == .jpeg || settings.format == .heic {
                    Slider(value: $settings.quality, in: 0.5...1) { Text("Quality \(Int(settings.quality * 100))") }
                }
                Picker("Colour space", selection: $settings.colorSpace) { ForEach(ExportSettings.ColorSpace.allCases, id: \.self) { Text($0.rawValue) } }
                if settings.format == .png || settings.format == .tiff { Toggle("16-bit", isOn: $settings.sixteenBit) }
                Picker("Metadata", selection: $settings.metadata) { ForEach(ExportSettings.Metadata.allCases, id: \.self) { Text($0.rawValue) } }
                TextField("Copyright", text: $settings.copyright)
                TextField("Watermark text", text: $settings.watermarkText)
                HStack {
                    Text(settings.watermarkImage.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No watermark image")
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .image]
                        if panel.runModal() == .OK { settings.watermarkImage = panel.url?.path }
                    }
                    if settings.watermarkImage != nil { Button("Clear") { settings.watermarkImage = nil } }
                }
                Picker("Watermark position", selection: $settings.watermarkPosition) {
                    ForEach(ExportSettings.WatermarkPosition.allCases, id: \.self) { Text($0.rawValue) }
                }
                Slider(value: $settings.watermarkSize, in: 1...15) { Text("Watermark size") }
                Slider(value: $settings.watermarkOpacity, in: 10...100) { Text("Watermark opacity") }
                TextField("File names ({name} {date} {seq} {camera})", text: $settings.naming)
            }
            .formStyle(.grouped).frame(width: 520, height: 470)
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }.keyboardShortcut(.defaultAction).disabled(running).accessibilityIdentifier("export-confirm")
            }
        }
        .padding(20)
        .onAppear { settings = store.presets.first ?? ExportSettings() }
    }

    private func export() {
        let env = ProcessInfo.processInfo.environment
        let testFolder = env["DARKROOM_DATA_DIR"].flatMap { _ in env["DARKROOM_TEST_EXPORT"] }.map { URL(fileURLWithPath: $0) }
        let folder: URL
        if let testFolder {
            try? FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
            folder = testFolder
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            folder = url
        }
        running = true
        let settings = self.settings, ids = self.ids, client = library.client
        Task {
            var done = 0
            let work = FileManager.default.temporaryDirectory.appending(path: "darkroom-export-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            for (n, id) in ids.enumerated() {
                library.statusMessage = "Exporting \(n + 1) of \(ids.count)…"
                do {
                    let asset = try await client.getAssetInfo(id: id)
                    let source = try await client.downloadOriginal(assetID: id, to: work.appending(path: "\(n)-\(asset.originalFileName)"),
                                                                   edited: settings.edited && asset.isEdited)
                    let named = work.appending(path: asset.originalFileName)
                    try? FileManager.default.removeItem(at: named)
                    try FileManager.default.moveItem(at: source, to: named)
                    _ = try await Task.detached { try Exporter.export(named, settings: settings, folder: folder, sequence: n + 1) }.value
                    done += 1
                } catch {
                    library.flash("Export of one item failed: \(error.localizedDescription)", isError: true)
                }
            }
            running = false
            library.flash("Exported \(done) item\(done == 1 ? "" : "s")")
            if testFolder == nil { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            dismiss()
        }
    }
}

// MARK: Quick Look and Share

@MainActor
final class QuickLooker: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLooker()
    var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { urls.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

extension LibraryModel {
    /// Preview-sized copies of the selection in a temporary folder (for Quick Look / Share).
    func previewFiles(original: Bool = false) async -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "darkroom-share")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for asset in targetAssets.prefix(original ? 50 : 20) {
            do {
                if original {
                    let info = try await client.getAssetInfo(id: asset.id)
                    out.append(try await client.downloadOriginal(assetID: asset.id, to: dir.appending(path: info.originalFileName), edited: info.isEdited))
                } else {
                    let data = try await pipeline.data(.init(assetID: asset.id, size: .preview, cacheKey: asset.cacheKey))
                    let url = dir.appending(path: "\(asset.id).jpg")
                    try data.write(to: url)
                    out.append(url)
                }
            } catch { continue }
        }
        return out
    }

    func quickLook() { Task { QuickLooker.shared.show(await previewFiles()) } }

    func share(from view: NSView?) {
        Task {
            let files = await previewFiles(original: true)
            guard !files.isEmpty else { return }
            let picker = NSSharingServicePicker(items: files)
            if let view = view ?? NSApp.keyWindow?.contentView {
                picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1), of: view, preferredEdge: .minY)
            }
        }
    }
}

// MARK: Shortcut cheat sheet (⌘/)

struct ShortcutCheatSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let groups: [(String, [(String, String)])] = [
        ("Library", [("G", "Grid"), ("E", "Loupe"), ("D", "Develop"), ("C", "Compare"), ("N", "Survey"), ("Tab / ⇧Tab", "Hide panels"),
                     ("F", "Full screen"), ("⌘F", "Search"), ("⌘[", "Back"), ("⌘↩", "Slideshow"), ("⌘Y", "Quick Look"), ("⇧⌘I", "Import"), ("⇧⌘E", "Export")]),
        ("Rating & flags", [("0–5", "Rating"), ("P", "Pick"), ("X", "Reject"), ("U", "Unflag"), ("H", "Favourite"), ("⌫", "Move to Immich trash")]),
        ("Organise", [("⇧⌘A", "Add to album"), ("⇧⌘T", "Tags"), ("⇧⌘D", "Date & time"), ("⇧⌘M", "Metadata"), ("⇧⌘L", "Location"),
                      ("⌘G / ⇧⌘G", "Stack / Unstack"), ("⌥⌘← / ⌥⌘→", "Rotate"), ("⌥⌘A", "Archive"), ("⌘E", "Edit in default editor"), ("⌃H / ⌃M", "Merge HDR / Panorama")]),
        ("Develop", [("R", "Crop"), ("W", "White balance picker"), ("V", "Black & white"), ("\\", "Before / after"), ("M / ⇧M", "Linear / radial mask"),
                     ("K", "Brush"), ("Q", "Spot removal"), ("O", "Mask overlay"), ("⌘U / ⇧⌘U", "Auto tone / white balance"),
                     ("⇧⌘C / ⇧⌘V", "Copy / paste settings"), ("⌃1–9", "Favourite presets"), ("⌘Z / ⇧⌘Z", "Undo / redo")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts").font(.title3.weight(.medium))
            HStack(alignment: .top, spacing: 28) {
                ForEach(groups, id: \.0) { title, items in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(items, id: \.0) { key, what in
                            HStack { Text(key).font(.caption.monospaced()).frame(width: 90, alignment: .leading); Text(what).font(.caption) }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .accessibilityIdentifier("cheat-sheet")
    }
}

// MARK: Menu-bar status

struct MenuBarStatus: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let library = state.activeLibrary {
            MenuBarContent(importModel: library.importer, editIn: library.editIn, rewrites: library.rewrites)
        } else {
            Text("DarkRoom is locked")
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var importModel: ImportModel
    @ObservedObject var editIn: EditInModel
    @ObservedObject var rewrites: FileRewriteQueue

    var body: some View {
        if let p = importModel.progress {
            Text("Uploading \(p.done) of \(p.total)")
            Button(importModel.isPaused ? "Resume Upload" : "Pause Upload") { importModel.togglePause() }
        } else {
            Text("No uploads in progress")
        }
        if !rewrites.pending.isEmpty { Text("Writing metadata into \(rewrites.pending.count) file\(rewrites.pending.count == 1 ? "" : "s")") }
        Divider()
        if editIn.sessions.isEmpty { Text("No companion edits") }
        ForEach(editIn.sessions) { session in
            Button("Done Editing \(session.assetName) (\(session.editor.name))") { Task { await editIn.finish(session) } }
        }
        Divider()
        Button("Show DarkRoom") { NSApp.activate(); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
    }
}
