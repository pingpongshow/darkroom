import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImmichAPI
import DarkRoomCore

extension UTType {
    static let darkroomPreset = UTType(exportedAs: "com.pingpongshow.darkroom.preset", conformingTo: .json)
}

/// Lightroom-style Presets panel (left side of Develop): hover to preview, click to apply, Amount slider.
struct PresetsPanel: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var develop: DevelopModel
    @State private var filter = ""
    @State private var expanded: Set<String> = ["Favorites", "Recent"]
    @State private var showSave = false
    @State private var renaming: Preset?
    @State private var newName = ""
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Presets").panelHeader()
                Spacer()
                Menu {
                    Button("Save Preset…") { showSave = true }.disabled(develop.recipe.isIdentity)
                    Button("Import Presets & Profiles…") { library.importPresetsWithPanel(); revision += 1 }
                    Button("Export All My Presets…") { library.exportPresets(develop.presets.all.filter { !$0.isBuiltIn }) }
                    Divider()
                    Toggle("Apply Camera Defaults Automatically", isOn: Binding(
                        get: { develop.presets.snapshot.autoApplyCameraDefaults },
                        set: { v in develop.presets.update { $0.autoApplyCameraDefaults = v }; revision += 1 }))
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).frame(width: 28)
                    .accessibilityIdentifier("presets-menu")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            TextField("Search presets", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal, 10)
                .accessibilityIdentifier("presets-search")
            if let applied = develop.appliedPreset {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(applied.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text("\(Int(develop.presetAmount))%").font(.caption.monospacedDigit())
                    }
                    Slider(value: Binding(get: { develop.presetAmount }, set: { develop.setPresetAmount($0, commit: false) }),
                           in: 0...200, step: 1, onEditingChanged: { if !$0 { develop.setPresetAmount(develop.presetAmount, commit: true) } })
                        .controlSize(.mini)
                        .accessibilityIdentifier("preset-amount")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
                .padding(10)
            }
            if let suggested = develop.suggestedDefault {
                HStack {
                    Image(systemName: "camera").foregroundStyle(Theme.highlight)
                    Text("Camera default: \(suggested.name)").font(.caption).lineLimit(2)
                    Spacer()
                    Button("Apply") { develop.apply(suggested) }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
                .padding(.horizontal, 10)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let state = develop.presets.snapshot
                    let all = develop.presets.all
                    if filter.isEmpty {
                        group("Favorites", state.favorites.compactMap { id in all.first { $0.id == id } })
                        group("Recent", state.recent.compactMap { id in all.first { $0.id == id } })
                        ForEach(develop.presets.folders, id: \.self) { folder in
                            group(folder, all.filter { $0.folder == folder })
                        }
                    } else {
                        ForEach(all.filter { $0.name.localizedCaseInsensitiveContains(filter) }) { row($0, state: state) }
                    }
                }
                .id(revision)
                .padding(.vertical, 6)
            }
        }
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("presets-panel")
        .sheet(isPresented: $showSave) {
            SavePresetSheet(develop: develop) { revision += 1 }
        }
        .sheet(item: $renaming) { preset in
            RenameSheet(title: "Rename Preset", name: $newName) { name in
                var p = preset; p.name = name; develop.presets.save(p); revision += 1
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ presets: [Preset]) -> some View {
        if !presets.isEmpty {
            let open = expanded.contains(title)
            Button {
                if open { expanded.remove(title) } else { expanded.insert(title) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Image(systemName: title == "Favorites" ? "star" : (title == "Recent" ? "clock" : "folder")).font(.caption)
                    Text(title).font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(presets.count)").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("preset-folder-\(title)")
            if open {
                let state = develop.presets.snapshot
                // The same preset can appear in Favorites, Recent and its folder: identity per section.
                ForEach(presets.map { (section: title, preset: $0) }, id: \.preset.id) { item in
                    row(item.preset, state: state).id("\(item.section)/\(item.preset.id)")
                }
                .id("section-\(title)")
            }
        }
    }

    private func row(_ preset: Preset, state: PresetStore.State) -> some View {
        let shortcut = state.shortcuts.first { $0.value == preset.id }?.key
        let isFavorite = state.favorites.contains(preset.id)
        return HStack(spacing: 6) {
            Text(preset.name).lineLimit(1)
            Spacer()
            if let shortcut { Text("⌃\(shortcut)").font(.caption2).foregroundStyle(Theme.textTertiary) }
            if isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
        }
        .font(.system(size: 11))
        .padding(.leading, 30).padding(.trailing, 10).padding(.vertical, 4)
        .background(develop.hoverPreset?.id == preset.id ? Theme.panelRaised : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { develop.hoverPreset = preset } else if develop.hoverPreset?.id == preset.id { develop.hoverPreset = nil }
        }
        .onTapGesture { develop.apply(preset); revision += 1 }
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") { develop.presets.toggleFavorite(preset.id); revision += 1 }
            Menu("Shortcut") {
                ForEach(1...9, id: \.self) { n in
                    Button("⌃\(n)\(state.shortcuts[n].flatMap { id in develop.presets.preset(id)?.name }.map { " (\($0))" } ?? "")") {
                        develop.presets.setShortcut(n, for: preset.id); revision += 1
                    }
                }
                Divider()
                Button("None") { develop.presets.setShortcut(nil, for: preset.id); revision += 1 }
            }
            Divider()
            if let exif = develop.context?.original.exifInfo {
                if let key = PresetStore.cameraKey(make: exif.make, model: exif.model) {
                    Button("Use as Default for \(key)") { develop.presets.update { $0.cameraDefaults[key] = preset.id }; revision += 1 }
                }
                if let lens = exif.lensModel {
                    Button("Use as Default for \(lens)") { develop.presets.update { $0.cameraDefaults["lens:\(lens)"] = preset.id }; revision += 1 }
                }
                Divider()
            }
            Button("Duplicate") { _ = develop.presets.duplicate(preset); revision += 1 }
            if !preset.isBuiltIn {
                Button("Rename…") { newName = preset.name; renaming = preset }
                Button("Update with Current Settings") {
                    var p = preset; p.recipe = develop.recipe; develop.presets.save(p); revision += 1
                }
            }
            Button("Export…") { library.exportPresets([preset]) }
            Divider()
            Button(preset.isBuiltIn ? "Hide" : "Delete", role: .destructive) { develop.presets.delete(preset.id); revision += 1 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("preset-\(preset.name)")
    }
}

struct SavePresetSheet: View {
    @ObservedObject var develop: DevelopModel
    var onSaved: () -> Void
    @State private var name = ""
    @State private var folder = "My Presets"
    @State private var groups: Set<RecipeGroup> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Preset").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("preset-name")
            HStack {
                TextField("Folder", text: $folder).textFieldStyle(.roundedBorder)
                Menu("Folders") {
                    ForEach(develop.presets.folders, id: \.self) { f in Button(f) { folder = f } }
                }
                .fixedSize()
            }
            Text("Include").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(RecipeGroup.allCases) { group in
                Toggle(group.rawValue, isOn: Binding(get: { groups.contains(group) },
                                                    set: { if $0 { groups.insert(group) } else { groups.remove(group) } }))
            }
            HStack {
                Button("Check Changed") { groups = RecipeGroup.changed(in: develop.recipe).intersection(RecipeGroup.looks) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    develop.saveAsPreset(name: name.trimmingCharacters(in: .whitespaces), folder: folder, groups: groups)
                    onSaved(); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || groups.isEmpty)
                .accessibilityIdentifier("preset-create")
            }
        }
        .padding(20).frame(width: 360)
        .onAppear { groups = RecipeGroup.changed(in: develop.recipe).intersection(RecipeGroup.looks) }
    }
}

// MARK: Library-level preset actions (batch, import, export)

extension LibraryModel {
    /// Applies a preset to photos without opening Develop (rendered and uploaded in the background).
    func applyPreset(_ preset: Preset, to ids: [String]) {
        guard !ids.isEmpty else { return }
        let develop = self.develop
        develop.presets.noteUsed(preset.id)
        if mode == .develop, ids == [develop.assetID].compactMap({ $0 }) {
            develop.apply(preset)
            return
        }
        Task {
            var done = 0
            for id in ids {
                statusMessage = "Applying “\(preset.name)” to \(done + 1) of \(ids.count)…"
                do {
                    let context = try await develop.versions.context(for: id)
                    let file = try await develop.originals.file(for: context.original)
                    let recipe = preset.apply(to: context.recipe)
                    _ = try await develop.versions.save(recipe, context: context, originalFile: file,
                                                        isLivePhoto: context.original.livePhotoVideoId != nil)
                    done += 1
                } catch {
                    flash("“\(preset.name)” couldn’t be applied to one photo: \(error.localizedDescription)", isError: true)
                }
            }
            flash("Applied “\(preset.name)” to \(done) photo\(done == 1 ? "" : "s")")
            await timeline.reload()
            detailsRevision += 1
        }
    }

    /// ⌃1…⌃9.
    func applyPresetShortcut(_ number: Int) {
        guard let id = develop.presets.snapshot.shortcuts[number], let preset = develop.presets.preset(id) else {
            flash("No preset assigned to ⌃\(number). Right-click a preset → Shortcut.", isError: true)
            return
        }
        applyPreset(preset, to: mode == .develop ? [develop.assetID].compactMap { $0 } : targetIDs)
    }

    func presetMenu() -> MenuEntry {
        let store = develop.presets
        let all = store.all
        let ids = targetIDs
        var children: [MenuEntry] = []
        let favorites = store.snapshot.favorites.compactMap { id in all.first { $0.id == id } }
        if !favorites.isEmpty {
            children += favorites.map { p in MenuEntry(title: "★ \(p.name)") { [weak self] in self?.applyPreset(p, to: ids) } }
            children.append(.separator)
        }
        for folder in store.folders {
            children.append(MenuEntry(title: folder, children: all.filter { $0.folder == folder }.map { p in
                MenuEntry(title: p.name) { [weak self] in self?.applyPreset(p, to: ids) }
            }))
        }
        return MenuEntry(title: "Presets", symbol: "camera.filters", isEnabled: !ids.isEmpty, children: children)
    }

    func importPresetsWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.darkroomPreset, UTType(filenameExtension: "xmp") ?? .xml,
                                     UTType(filenameExtension: "cube") ?? .data, UTType(filenameExtension: "lrtemplate") ?? .data]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importPresetFiles(panel.urls)
    }

    func importPresetFiles(_ urls: [URL]) {
        var count = 0
        var notes: [String] = []
        for url in urls {
            do {
                let (presets, report) = try develop.presets.importFile(url)
                count += presets.count
                notes += report
            } catch {
                notes.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        develop.objectWillChange.send()
        flash("Imported \(count) preset\(count == 1 ? "" : "s")" + (notes.isEmpty ? "" : ". " + notes.joined(separator: " · ")),
              isError: count == 0 && !notes.isEmpty)
    }

    func exportPresets(_ presets: [Preset]) {
        guard !presets.isEmpty else { flash("No presets to export", isError: true); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.darkroomPreset]
        panel.nameFieldStringValue = presets.count == 1 ? presets[0].name : "DarkRoom Presets"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try develop.presets.export(presets).write(to: url, options: .atomic)
            flash("Exported \(presets.count) preset\(presets.count == 1 ? "" : "s")")
        } catch {
            flash("Export failed: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: Rotate (photos: Immich built-in edit or version; videos: lossless) and Make Still

extension LibraryModel {
    /// Rotates the selected items by quarter turns (+1 = right / clockwise).
    func rotateSelection(_ delta: Int) {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        let develop = self.develop
        Task {
            var done = 0
            for id in ids {
                statusMessage = "Rotating \(done + 1) of \(ids.count)…"
                do {
                    let context = try await develop.versions.context(for: id)
                    var recipe = context.recipe
                    recipe.geometry.quarterTurns = (((recipe.geometry.quarterTurns + delta) % 4) + 4) % 4
                    let file = try await develop.originals.file(for: context.original)
                    _ = try await develop.versions.save(recipe, context: context, originalFile: file,
                                                        isLivePhoto: context.original.livePhotoVideoId != nil)
                    done += 1
                } catch {
                    flash("Couldn’t rotate: \(error.localizedDescription)", isError: true)
                }
            }
            flash("Rotated \(done) item\(done == 1 ? "" : "s")")
            await pipeline.invalidate(assetID: ids[0])
            await timeline.reload()
            detailsRevision += 1
        }
    }

    /// Make Still: keeps the photo, sends the motion clip to Immich's trash (undoable).
    func makeStill() {
        let ids = targetAssets.filter(\.isLivePhoto).map(\.id)
        guard !ids.isEmpty else { return }
        perform("Make Still", ids: ids, change: .metadata(ids: ids)) { actions in
            var undos: [UndoAction] = []
            for id in ids { undos.append(try await actions.makeStill(id)) }
            let steps = undos
            return UndoAction(name: "Make Still") { for u in steps.reversed() { try await u.run() } }
        }
    }
}
