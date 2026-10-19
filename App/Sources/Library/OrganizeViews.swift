import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

// MARK: Memories

/// "On this day" cards above the Photos grid.
struct MemoriesStrip: View {
    @EnvironmentObject var library: LibraryModel
    @State private var memories: [MemoryResponseDto] = []
    @AppStorage("showMemories", store: .darkRoom) private var show = true

    var body: some View {
        if show && !memories.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(memories, id: \.id) { memory in
                        Button { open(memory) } label: {
                            Color.clear.frame(width: 150, height: 96)
                                .overlay {
                                    if let first = memory.assets.first {
                                        PipelineImage(asset: TimelineAsset(first), size: .thumbnail, maxPixel: 320)
                                    }
                                }
                                .clipped()
                                .overlay(alignment: .bottomLeading) {
                                    Text(title(memory)).font(.caption.weight(.semibold)).foregroundStyle(.white)
                                        .shadow(radius: 3).padding(6)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("memory-\(memory.data.year)")
                    }
                    Button { show = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Hide memories (turn back on in Preferences)")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Theme.panel)
        } else {
            Color.clear.frame(height: 0)
                .task { memories = (try? await LibraryUtilities.memoriesForToday(library.client)) ?? [] }
        }
    }

    private func title(_ memory: MemoryResponseDto) -> String {
        let years = Calendar.current.component(.year, from: .now) - memory.data.year
        if let name = memory.data.personName, memory.type == .birthday { return "\(name)’s birthday" }
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    private func open(_ memory: MemoryResponseDto) {
        library.slideshow = SlideshowRequest(assets: memory.assets.map(TimelineAsset.init), title: title(memory))
        Task { _ = try? await library.client.updateMemory(id: memory.id, body: MemoryUpdateDto(seenAt: ImmichDate.format(.now))) }
    }
}

// MARK: Slideshow

struct SlideshowRequest: Identifiable {
    let id = UUID()
    var assets: [TimelineAsset]
    var title: String?
    var start = 0
}

extension LibraryModel {
    /// ⌘↩: the selection (or the whole current view) as a slideshow.
    func startSlideshow() {
        let ids = Set(targetIDs)
        let assets = ids.count > 1 ? orderedAssets.filter { ids.contains($0.id) } : orderedAssets
        guard !assets.isEmpty else { return }
        let start = focusedAssetID.flatMap { id in assets.firstIndex { $0.id == id } } ?? 0
        slideshow = SlideshowRequest(assets: assets.filter(\.isImage), title: title, start: ids.count > 1 ? 0 : start)
    }
}

/// Full-window slideshow with cross-fades and a slow zoom. Space pauses, arrows step, Esc exits.
struct SlideshowView: View {
    @EnvironmentObject var library: LibraryModel
    let request: SlideshowRequest
    @AppStorage("slideshowSeconds", store: .darkRoom) private var seconds = 4.0
    @AppStorage("slideshowKenBurns", store: .darkRoom) private var kenBurns = true
    @State private var index = 0
    @State private var image: CGImage?
    @State private var paused = false
    @State private var zoom = 1.0
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(image, scale: 1, label: Text("Slide"))
                    .resizable().scaledToFit()
                    .accessibilityIdentifier("slideshow-image")
                    .scaleEffect(zoom)
                    .id(index)
                    .transition(.opacity)
                    .zIndex(1)
                    .padding(.vertical, 50)
            }
            VStack {
                HStack {
                    if let title = request.title { Text(title).font(.headline).foregroundStyle(.white.opacity(0.8)) }
                    Spacer()
                    Text("\(index + 1) / \(request.assets.count)").foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                    Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                        .accessibilityIdentifier("slideshow-close")
                }
                Spacer()
                if paused { Image(systemName: "pause.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.6)) }
                Spacer()
            }
            .padding(20)
            .zIndex(2)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow")
        .task(id: index) { await show() }
        .task(id: paused) {
            while !paused && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if paused || Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % max(1, request.assets.count) }
            }
        }
        .onAppear {
            index = min(request.start, max(0, request.assets.count - 1))
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 53: close(); return nil                                   // Esc
                case 49: paused.toggle(); return nil                           // Space
                case 123: step(-1); return nil                                 // ←
                case 124: step(1); return nil                                  // →
                default: return event
                }
            }
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    }

    private func step(_ delta: Int) {
        let count = max(1, request.assets.count)
        withAnimation(.easeInOut(duration: 0.4)) { index = (index + delta + count) % count }
    }

    private func show() async {
        guard let asset = request.assets[safe: index] else { return }
        let next = request.assets[safe: (index + 1) % max(1, request.assets.count)]
        let loadedImage: CGImage?
        do { loadedImage = try await library.pipeline.image(.init(assetID: asset.id, size: .preview, cacheKey: asset.cacheKey)) }
        catch { loadedImage = nil }
        if let loaded = loadedImage {
            withAnimation(.easeInOut(duration: 0.8)) { image = loaded }
            zoom = 1.0
            if kenBurns { withAnimation(.linear(duration: seconds + 1)) { zoom = 1.06 } }
        }
        if let next { await library.pipeline.prefetch([.init(assetID: next.id, size: .preview, cacheKey: next.cacheKey)]) }
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        library.slideshow = nil
    }
}

// MARK: Tags

struct TagNode: Identifiable, Hashable {
    let tag: TagResponseDto
    var children: [TagNode]
    var id: String { tag.id }
    var childrenOrNil: [TagNode]? { children.isEmpty ? nil : children }
}

extension TagResponseDto: @retroactive Identifiable {}

struct TagsView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var tags: [TagResponseDto] = []
    @State private var newTag = ""
    @State private var renaming: TagResponseDto?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("New tag (use / to nest)", text: $newTag).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onSubmit(create)
                    .accessibilityIdentifier("tags-new")
                Button("Add", action: create).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Text("\(tags.count) tags").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            List {
                if tags.isEmpty { Text("No tags yet. Add tags to photos with ⇧⌘T.").foregroundStyle(Theme.textTertiary) }
                OutlineGroup(tree, children: \.childrenOrNil) { node in
                    HStack {
                        Circle().fill(color(node.tag.color)).frame(width: 8, height: 8)
                        Text(node.tag.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        library.tagNames[node.tag.id] = node.tag.value
                        library.destination = .tag(node.tag.id)
                    }
                    .contextMenu {
                        Button("Rename…") { newName = node.tag.name; renaming = node.tag }
                        Menu("Colour") {
                            ForEach(["#e5484d", "#f76b15", "#ffc53d", "#46a758", "#0090ff", "#8e4ec6", "#8b8d98"], id: \.self) { hex in
                                Button { setColor(node.tag, hex) } label: { Text(hex) }
                            }
                        }
                        Divider()
                        Button("Delete Tag", role: .destructive) { delete(node.tag) }
                    }
                    .accessibilityIdentifier("tag-\(node.tag.value)")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Theme.gridBackground)
        .task { await load() }
        .sheet(item: $renaming) { tag in
            RenameSheet(title: "Rename Tag", name: $newName) { name in
                Task { _ = try? await library.client.updateTag(id: tag.id, body: TagUpdateDto(name: name)); await load() }
            }
        }
    }

    private var tree: [TagNode] {
        let visible = tags.filter { !$0.value.hasPrefix("Culling") }
        func children(of parent: String?) -> [TagNode] {
            visible.filter { $0.parentId == parent }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { TagNode(tag: $0, children: children(of: $0.id)) }
        }
        return children(of: nil)
    }

    private func color(_ hex: String?) -> Color {
        guard let hex, let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return Theme.textTertiary }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    private func load() async {
        tags = (try? await library.client.getAllTags()) ?? []
        for tag in tags { library.tagNames[tag.id] = tag.value }
    }

    private func create() {
        let name = newTag.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newTag = ""
        Task { _ = try? await library.client.upsertTags(body: TagUpsertDto(tags: [name])); await load() }
    }

    private func setColor(_ tag: TagResponseDto, _ hex: String) {
        Task { _ = try? await library.client.updateTag(id: tag.id, body: TagUpdateDto(color: hex)); await load() }
    }

    private func delete(_ tag: TagResponseDto) {
        Task { try? await library.client.deleteTag(id: tag.id); await load() }
    }
}

// MARK: Folders

struct FoldersView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var tree: [LibraryUtilities.Folder] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && tree.isEmpty { Text("No folders").foregroundStyle(Theme.textTertiary) }
            OutlineGroup(tree, children: \.childrenOrNil) { folder in
                Label(folder.name, systemImage: "folder")
                    .contentShape(Rectangle())
                    .onTapGesture { library.destination = .folder(folder.path) }
                    .accessibilityIdentifier("folder-\(folder.name)")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.gridBackground)
        .task {
            tree = LibraryUtilities.folderTree((try? await library.client.getUniqueOriginalPaths()) ?? [])
            loaded = true
        }
    }
}

struct FolderPathBar: View {
    @EnvironmentObject var library: LibraryModel
    let path: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").foregroundStyle(Theme.textTertiary)
            Text(path).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.head)
            Spacer()
            Button("All Folders") { library.destination = .folders }.buttonStyle(.link)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.panel)
    }
}

// MARK: Locked folder

/// Immich's locked folder needs the user's Immich PIN (set up once; different from the DarkRoom PIN).
struct LockedFolderGate: View {
    @EnvironmentObject var library: LibraryModel
    @State private var state: LibraryUtilities.LockedState?
    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.textTertiary)
            Text("Locked Folder").font(.title2.weight(.light))
            switch state {
            case .needsSetup:
                Text("Create a 6-digit PIN for your Immich locked folder.\nIt’s the same PIN Immich web and the phone app use.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.textSecondary)
                SecureField("PIN", text: $pin).frame(width: 160).accessibilityIdentifier("locked-pin")
                SecureField("Confirm PIN", text: $confirm).frame(width: 160).onSubmit(setUp)
                Button("Create PIN", action: setUp).keyboardShortcut(.defaultAction)
            case .locked, .unlocked:
                Text("Enter your Immich locked-folder PIN").foregroundStyle(Theme.textSecondary)
                SecureField("PIN", text: $pin).frame(width: 160).onSubmit(unlock).accessibilityIdentifier("locked-pin")
                Button("Unlock", action: unlock).keyboardShortcut(.defaultAction).accessibilityIdentifier("locked-unlock")
            case nil:
                ProgressView()
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.gridBackground)
        .task { state = try? await LibraryUtilities.lockedState(library.client) }
    }

    private var validPIN: Bool { pin.count == 6 && pin.allSatisfy(\.isNumber) }

    private func setUp() {
        guard validPIN else { error = "The PIN must be 6 digits"; return }
        guard pin == confirm else { error = "The PINs don’t match"; return }
        Task {
            do {
                try await LibraryUtilities.setUpLockedFolderPIN(library.client, pin: pin)
                try await LibraryUtilities.unlockLockedFolder(library.client, pin: pin)
                opened()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func unlock() {
        Task {
            do {
                try await LibraryUtilities.unlockLockedFolder(library.client, pin: pin)
                opened()
            } catch { self.error = "Wrong PIN"; pin = "" }
        }
    }

    private func opened() {
        pin = ""; confirm = ""
        library.lockedUnlocked = true
        Task { await library.timeline.reload() }
    }
}

// MARK: Duplicates

struct DuplicatesView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var groups: [DuplicateResponseDto] = []
    @State private var keep: [String: Set<String>] = [:]
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loaded && groups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textTertiary)
                        Text("No duplicates found. Immich checks new uploads automatically.").foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity).padding(60)
                    .accessibilityIdentifier("duplicates-empty")
                }
                if !groups.isEmpty {
                    Text("\(groups.count) groups · click photos to choose which to keep").foregroundStyle(Theme.textSecondary)
                }
                ForEach(groups, id: \.duplicateId) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(group.assets, id: \.id) { asset in
                                    let kept = keep[group.duplicateId, default: Set(group.suggestedKeepAssetIds)].contains(asset.id)
                                    VStack(alignment: .leading, spacing: 3) {
                                        PipelineImage(asset: TimelineAsset(asset), size: .thumbnail, maxPixel: 400)
                                            .frame(width: 200, height: 200).clipped()
                                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(kept ? Color.green : Theme.danger, lineWidth: 3))
                                            .overlay(alignment: .topLeading) {
                                                Text(kept ? "Keep" : "Trash").font(.caption.weight(.bold)).padding(4)
                                                    .background(kept ? Color.green : Theme.danger).foregroundStyle(.white).padding(4)
                                            }
                                            .onTapGesture { toggle(group, asset.id) }
                                        Text(asset.originalFileName).font(.caption).lineLimit(1)
                                        Text(details(asset)).font(.caption2).foregroundStyle(Theme.textTertiary)
                                    }
                                    .frame(width: 200)
                                }
                            }
                        }
                        HStack {
                            Button("Keep Selected, Trash Others") { resolve(group) }
                            Button("Stack Them") { stack(group) }
                            Button("Not Duplicates") { notDuplicates(group) }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                }
            }
            .padding(18)
        }
        .background(Theme.gridBackground)
        .task { await load() }
    }

    private func details(_ asset: AssetResponseDto) -> String {
        var parts: [String] = []
        if let e = asset.exifInfo {
            if let w = e.exifImageWidth, let h = e.exifImageHeight { parts.append("\(w)×\(h)") }
            if let size = ExifText.fileSize(e) { parts.append(size) }
        }
        if let date = ImmichDate.parse(asset.localDateTime) { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private func toggle(_ group: DuplicateResponseDto, _ id: String) {
        var set = keep[group.duplicateId, default: Set(group.suggestedKeepAssetIds)]
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        keep[group.duplicateId] = set
    }

    private func load() async {
        groups = (try? await library.client.getAssetDuplicates()) ?? []
        loaded = true
    }

    private func resolve(_ group: DuplicateResponseDto) {
        let chosen = keep[group.duplicateId, default: Set(group.suggestedKeepAssetIds)]
        guard !chosen.isEmpty else { library.flash("Keep at least one photo", isError: true); return }
        Task {
            do {
                try await LibraryUtilities.resolveDuplicates(library.client, group: group, keep: chosen)
                let trashed = group.assets.map(\.id).filter { !chosen.contains($0) }
                library.undoManager?.registerUndo(withTarget: library) { model in
                    Task { _ = try? await model.client.restoreAssets(body: BulkIdsDto(ids: trashed)) }
                }
                library.undoManager?.setActionName("Resolve Duplicates")
                library.flash("Moved \(trashed.count) duplicate\(trashed.count == 1 ? "" : "s") to the trash")
                await load()
            } catch { library.flash("Couldn’t resolve: \(error.localizedDescription)", isError: true) }
        }
    }

    private func stack(_ group: DuplicateResponseDto) {
        let cover = keep[group.duplicateId, default: Set(group.suggestedKeepAssetIds)].first ?? group.assets[0].id
        Task {
            do { try await LibraryUtilities.stackDuplicates(library.client, group: group, cover: cover); await load() }
            catch { library.flash("Couldn’t stack: \(error.localizedDescription)", isError: true) }
        }
    }

    private func notDuplicates(_ group: DuplicateResponseDto) {
        Task {
            do { try await LibraryUtilities.resolveDuplicates(library.client, group: group, keep: Set(group.assets.map(\.id))); await load() }
            catch { library.flash("Couldn’t update: \(error.localizedDescription)", isError: true) }
        }
    }
}

// MARK: Bursts

struct BurstsView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var bursts: [[TimelineAsset]] = []
    @State private var loaded = false
    @State private var open: BurstGroup?

    var body: some View {
        ScrollView {
            if !loaded { ProgressView().padding(60) }
            if loaded && bursts.isEmpty {
                Text("No bursts found. Bursts are 3 or more photos taken within a second of each other.")
                    .foregroundStyle(Theme.textSecondary).padding(60)
                    .accessibilityIdentifier("bursts-empty")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                ForEach(bursts, id: \.first!.id) { frames in
                    Button { open = BurstGroup(frames: frames) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                ForEach(Array(frames.prefix(3).enumerated().reversed()), id: \.offset) { offset, frame in
                                    PipelineImage(asset: frame, size: .thumbnail, maxPixel: 320)
                                        .frame(width: 160, height: 120).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .offset(x: CGFloat(offset) * 6, y: CGFloat(offset) * -6)
                                }
                            }
                            .frame(height: 140)
                            Text("\(frames.count) frames").foregroundStyle(Theme.text)
                            Text(frames[0].localDate.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: TimeZone(identifier: "UTC")!)))
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(Theme.gridBackground)
        .task { await reload() }
        .sheet(item: $open) { group in
            BurstPickerSheet(frames: group.frames) { Task { await reload() } }.environmentObject(library)
        }
    }

    private func reload() async {
        bursts = LibraryUtilities.bursts(in: await library.allTimelineAssets())
        loaded = true
    }
}

struct BurstGroup: Identifiable {
    let id = UUID()
    let frames: [TimelineAsset]
}

/// Pick the best frame(s) of a burst; stack the rest under the first pick, or trash them.
struct BurstPickerSheet: View {
    @EnvironmentObject var library: LibraryModel
    let frames: [TimelineAsset]
    var onDone: () -> Void
    @State private var picks: [String] = []
    @State private var focused: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the best frames").font(.headline)
            if let focused, let asset = frames.first(where: { $0.id == focused }) {
                PipelineImage(asset: asset, size: .preview, maxPixel: 1400).scaledToFit()
                    .frame(width: 720, height: 400)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(frames) { frame in
                        PipelineImage(asset: frame, size: .thumbnail, maxPixel: 200)
                            .frame(width: 90, height: 90).clipped()
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(picks.contains(frame.id) ? Color.green : (focused == frame.id ? Theme.highlight : .clear), lineWidth: 3))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: picks.contains(frame.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.white).shadow(radius: 2).padding(4)
                                    .onTapGesture { togglePick(frame.id) }
                            }
                            .onTapGesture { focused = frame.id }
                    }
                }
            }
            .frame(width: 720)
            HStack {
                Text(picks.isEmpty ? "Tick the frames to keep" : "\(picks.count) picked").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Trash Others") { trashOthers() }.disabled(picks.isEmpty)
                Button("Stack Under Pick") { stack() }.disabled(picks.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { focused = frames.first?.id }
    }

    private func togglePick(_ id: String) {
        if let i = picks.firstIndex(of: id) { picks.remove(at: i) } else { picks.append(id) }
    }

    private func stack() {
        let frames = frames.map(\.id), picks = picks
        library.perform("Stack Burst", ids: frames, change: .stacked(ids: frames)) { actions in
            try await LibraryUtilities.stackBurst(actions.client, frames: frames, picks: picks)
        }
        dismiss(); onDone()
    }

    private func trashOthers() {
        let others = frames.map(\.id).filter { !picks.contains($0) }
        library.perform("Move to Trash", ids: others, change: .trashed(ids: others)) { try await $0.trash(others) }
        dismiss(); onDone()
    }
}

// MARK: Stack strip (loupe)

/// The other items in a stack: set the cover, take one out.
struct StackStrip: View {
    @EnvironmentObject var library: LibraryModel
    let asset: TimelineAsset
    @State private var stack: StackResponseDto?

    var body: some View {
        HStack(spacing: 6) {
            Text("Stack").panelHeader()
            if let stack {
                ForEach(stack.assets, id: \.id) { member in
                    PipelineImage(asset: TimelineAsset(member), size: .thumbnail, maxPixel: 120)
                        .frame(width: 44, height: 44).clipped()
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(member.id == stack.primaryAssetId ? Theme.highlight : .clear, lineWidth: 2))
                        .help(member.originalFileName)
                        .contextMenu {
                            Button("Set as Stack Cover") { setCover(member.id) }.disabled(member.id == stack.primaryAssetId)
                            Button("Remove from Stack") { remove(member.id) }
                        }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stack-strip")
        .task(id: asset.stackID) {
            if let id = asset.stackID { stack = try? await library.client.getStack(id: id) }
        }
    }

    private func setCover(_ id: String) {
        guard let stackID = stack?.id else { return }
        library.perform("Set Stack Cover", ids: [id], change: .stacked(ids: [id])) { try await $0.setStackPrimary(stackID: stackID, assetID: id) }
        Task { try? await Task.sleep(for: .seconds(1)); await library.timeline.reload() }
    }

    private func remove(_ id: String) {
        guard let stackID = stack?.id else { return }
        Task {
            try? await library.client.removeAssetFromStack(assetId: id, id: stackID)
            await library.timeline.reload()
            stack = try? await library.client.getStack(id: stackID)
        }
    }
}
