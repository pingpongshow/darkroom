import SwiftUI
import MapKit
import ImmichAPI
import DarkRoomCore

/// Presents whichever sheet the library asked for.
struct LibrarySheetView: View {
    @EnvironmentObject var library: LibraryModel
    let sheet: LibrarySheet

    var body: some View {
        switch sheet {
        case .dateTime(let ids): DateTimeSheet(ids: ids)
        case .metadata(let ids): MetadataSheet(ids: ids)
        case .albumPicker(let ids): AlbumPickerSheet(ids: ids)
        case .newAlbum(let ids): NewAlbumSheet(ids: ids)
        case .tags(let ids): TagsSheet(ids: ids)
        case .geotag(let ids): GeotagSheet(ids: ids)
        case .confirmEmptyTrash: EmptyView()
        case .editAlbum(let id): EditAlbumSheet(albumID: id)
        case .shareAlbum(let id): ShareAlbumSheet(albumID: id)
        case .sharedLink(let albumID, let ids): SharedLinkSheet(albumID: albumID, assetIDs: ids)
        case .importReview: ImportSheet(model: library.importer)
        case .export(let ids): ExportSheet(ids: ids)
        case .shortcuts: ShortcutCheatSheet()
        case .tour: OnboardingTour()
        }
    }
}

private struct SheetFrame<Content: View>: View {
    let title: String
    var subtitle: String?
    var confirm: String
    var confirmDisabled = false
    var onConfirm: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm) { onConfirm(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmDisabled)
                    .accessibilityIdentifier("sheet-confirm")
            }
        }
        .padding(20)
    }
}

private func itemsLabel(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

// MARK: Date & time

/// Sets an exact capture date and time: pick it on the calendar or type it, in the photo's time zone,
/// with a before/after preview.
struct DateTimeSheet: View {
    @EnvironmentObject var library: LibraryModel
    let ids: [String]
    @State private var date = Date()
    @State private var zone = TimeZone.current.identifier
    @State private var assets: [AssetResponseDto] = []
    @State private var initialized = false

    private var timeZone: TimeZone { TimeZone(identifier: zone) ?? .current }

    var body: some View {
        SheetFrame(title: "Set Date & Time", subtitle: "\(itemsLabel(ids.count)) · original files aren’t changed",
                   confirm: "Set", onConfirm: apply) {
            HStack(alignment: .top, spacing: 22) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 200)
                    .accessibilityIdentifier("date-calendar")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                    GridRow {
                        Text("Date").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.field).labelsHidden()
                            .accessibilityIdentifier("date-field")
                    }
                    GridRow {
                        Text("Time").foregroundStyle(.secondary)
                        DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                            .datePickerStyle(.field).labelsHidden()
                            .accessibilityIdentifier("time-field")
                    }
                    GridRow {
                        Text("Time zone").foregroundStyle(.secondary)
                        Picker("", selection: $zone) {
                            ForEach(Self.zones, id: \.self) { Text(Self.zoneLabel($0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 250)
                        .accessibilityIdentifier("date-zone")
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        HStack(spacing: 12) {
                            Button("Now") { date = Date() }
                            if let first = assets.first, captureDate(first) != nil {
                                Button("Reset to Photo’s Date") { useDate(of: first) }
                                    .help("Back to the first photo’s current date and time")
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.top, 6)
            }
            // The calendar and fields show wall-clock time in the chosen zone.
            .environment(\.timeZone, timeZone)

            Divider()
            Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(assets.prefix(50), id: \.id) { asset in
                        HStack(spacing: 8) {
                            Text(asset.originalFileName).lineLimit(1).truncationMode(.middle)
                                .frame(width: 180, alignment: .leading)
                            Text(format(captureDate(asset))).foregroundStyle(.secondary).monospacedDigit()
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(format(newDate)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                    if assets.count > 50 {
                        Text("and \(assets.count - 50) more").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(width: 520, height: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
        }
        .task {
            assets = (try? await library.actions.details(ids)) ?? []
            if !initialized, let first = assets.first { useDate(of: first) }
            initialized = true
        }
    }

    /// Every known zone, west to east.
    private static let zones: [String] = TimeZone.knownTimeZoneIdentifiers.sorted {
        let a = TimeZone(identifier: $0)?.secondsFromGMT() ?? 0, b = TimeZone(identifier: $1)?.secondsFromGMT() ?? 0
        return a != b ? a < b : $0 < $1
    }

    private static func zoneLabel(_ identifier: String) -> String {
        let seconds = TimeZone(identifier: identifier)?.secondsFromGMT() ?? 0
        let sign = seconds < 0 ? "−" : "+"
        let offset = String(format: "GMT%@%02d:%02d", sign, abs(seconds) / 3600, abs(seconds) / 60 % 60)
        return "(\(offset)) \(identifier.replacingOccurrences(of: "_", with: " "))"
    }

    /// Starts from a photo's capture time, in its own time zone when Immich knows it.
    private func useDate(of asset: AssetResponseDto) {
        guard let local = captureDate(asset) else { return }
        let created = ImmichDate.parse(asset.fileCreatedAt) ?? local
        let offset = Int(local.timeIntervalSince(created).rounded())
        if let name = asset.exifInfo?.timeZone, TimeZone(identifier: name) != nil, Self.zones.contains(name) {
            zone = name
        } else if timeZone.secondsFromGMT(for: created) != offset,
                  let match = Self.zones.first(where: { TimeZone(identifier: $0)?.secondsFromGMT(for: created) == offset }) {
            zone = match
        }
        date = created
    }

    /// Immich's local date-time: wall-clock time expressed as UTC.
    private func captureDate(_ asset: AssetResponseDto) -> Date? { ImmichDate.parse(asset.localDateTime) }

    private var newDate: Date { date.addingTimeInterval(Double(timeZone.secondsFromGMT(for: date))) }

    private func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: TimeZone(identifier: "UTC")!))
    }

    private func apply() {
        let date = self.date, tz = timeZone
        library.perform("Set Date & Time", ids: ids, change: .metadata(ids: ids), rewritesFiles: true) { try await $0.setDate(ids, to: date, timeZone: tz) }
        Task { try? await Task.sleep(for: .seconds(2)); await library.timeline.reload() }
    }
}

// MARK: Batch metadata

/// Batch edit: only the fields switched on are changed.
struct MetadataSheet: View {
    @EnvironmentObject var library: LibraryModel
    let ids: [String]
    @State private var changeDescription = false
    @State private var description = ""
    @State private var changeRating = false
    @State private var rating = 0
    @State private var favorite = 0   // 0 unchanged, 1 yes, 2 no
    @State private var archive = 0
    @State private var tags = ""

    var body: some View {
        SheetFrame(title: "Edit Metadata", subtitle: "\(itemsLabel(ids.count)) · fields left off stay unchanged",
                   confirm: "Apply", onConfirm: apply) {
            Form {
                Toggle("Description", isOn: $changeDescription).accessibilityIdentifier("meta-change-description")
                if changeDescription {
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...4)
                        .accessibilityIdentifier("meta-description")
                }
                Toggle("Rating", isOn: $changeRating)
                if changeRating {
                    Picker("Stars", selection: $rating) {
                        Text("None").tag(0)
                        ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                    }
                }
                Picker("Favorite", selection: $favorite) { Text("Unchanged").tag(0); Text("Yes").tag(1); Text("No").tag(2) }
                Picker("Archived", selection: $archive) { Text("Unchanged").tag(0); Text("Yes").tag(1); Text("No").tag(2) }
                TextField("Add tags (comma separated, use / to nest)", text: $tags).accessibilityIdentifier("meta-tags")
            }
            .formStyle(.grouped)
            .frame(width: 440)
        }
    }

    private func apply() {
        let ids = ids
        let description = changeDescription ? description : nil
        let rating = changeRating ? rating : nil
        let favorite: Bool? = favorite == 0 ? nil : favorite == 1
        let visibility: AssetVisibility? = archive == 0 ? nil : (archive == 1 ? .archive : .timeline)
        let tagNames = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let touchesFile = description != nil || rating != nil || !tagNames.isEmpty
        library.perform("Edit Metadata", ids: ids, change: .metadata(ids: ids), rewritesFiles: touchesFile) { actions in
            var undos: [UndoAction] = []
            if let description { undos.append(try await actions.setDescription(ids, description)) }
            if let rating { undos.append(try await actions.setRating(ids, rating)) }
            if let favorite { undos.append(try await actions.setFavorite(ids, favorite)) }
            if let visibility { undos.append(try await actions.setVisibility(ids, visibility)) }
            if !tagNames.isEmpty {
                let created = try await actions.client.upsertTags(body: TagUpsertDto(tags: tagNames))
                let leafIDs = created.filter { tag in tagNames.contains(tag.value) }.map(\.id)
                undos.append(try await actions.tag(ids, tagIDs: leafIDs))
            }
            let steps = undos
            return UndoAction(name: "Edit Metadata") {
                for undo in steps.reversed() { try await undo.run() }
            }
        }
        if visibility != nil { Task { try? await Task.sleep(for: .seconds(1)); await library.timeline.reload() } }
    }
}

// MARK: Albums

struct AlbumPickerSheet: View {
    @EnvironmentObject var library: LibraryModel
    let ids: [String]
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add \(itemsLabel(ids.count)) to Album").font(.headline)
            TextField("Search albums", text: $filter).textFieldStyle(.roundedBorder).accessibilityIdentifier("album-filter")
            List(filtered, id: \.id) { album in
                Button {
                    library.addToAlbum(album)
                    dismiss()
                } label: {
                    HStack {
                        AlbumCover(album: album, size: 36)
                        VStack(alignment: .leading) {
                            Text(album.albumName)
                            Text("\(album.assetCount) items\(album.shared ? " · shared" : "")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pick-album-\(album.albumName)")
            }
            .frame(width: 380, height: 300)
            HStack {
                Button("New Album…") { library.sheet = .newAlbum(ids) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .task { await library.loadAlbums() }
    }

    private var filtered: [AlbumResponseDto] {
        library.albums.filter { filter.isEmpty || $0.albumName.localizedCaseInsensitiveContains(filter) }
    }
}

struct NewAlbumSheet: View {
    @EnvironmentObject var library: LibraryModel
    let ids: [String]
    @State private var name = ""
    @State private var description = ""

    var body: some View {
        SheetFrame(title: "New Album", subtitle: ids.isEmpty ? nil : "With \(itemsLabel(ids.count))",
                   confirm: "Create", confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty, onConfirm: create) {
            TextField("Album name", text: $name).textFieldStyle(.roundedBorder).frame(width: 320)
                .accessibilityIdentifier("new-album-name")
            TextField("Description (optional)", text: $description).textFieldStyle(.roundedBorder).frame(width: 320)
        }
    }

    private func create() {
        let name = name.trimmingCharacters(in: .whitespaces), description = description, ids = ids
        Task {
            do {
                let (album, undo) = try await library.actions.createAlbum(name: name, description: description, assetIDs: ids)
                await library.loadAlbums()
                library.recentAlbumIDs.insert(album.id, at: 0)
                library.undoManager?.registerUndo(withTarget: library) { model in
                    Task { try? await undo.run(); await model.loadAlbums() }
                }
                library.undoManager?.setActionName("New Album")
                library.flash("Created “\(name)”")
            } catch {
                library.flash("Couldn’t create album: \(error.localizedDescription)", isError: true)
            }
        }
    }
}

/// Small album cover (the album's thumbnail asset).
struct AlbumCover: View {
    @EnvironmentObject var library: LibraryModel
    let album: AlbumResponseDto
    var size: CGFloat
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Theme.panelRaised)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: "rectangle.stack").foregroundStyle(Theme.textTertiary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: album.albumThumbnailAssetId) {
            guard let id = album.albumThumbnailAssetId else { return }
            image = try? await library.pipeline.image(.init(assetID: id, size: .thumbnail, cacheKey: album.updatedAt), maxPixel: Int(size * 2))
        }
    }
}

// MARK: Tags

struct TagsSheet: View {
    @EnvironmentObject var library: LibraryModel
    let ids: [String]
    @State private var tags: [TagResponseDto] = []
    @State private var chosen: Set<String> = []
    @State private var newTag = ""

    var body: some View {
        SheetFrame(title: "Add Tags", subtitle: itemsLabel(ids.count), confirm: "Add",
                   confirmDisabled: chosen.isEmpty && newTag.trimmingCharacters(in: .whitespaces).isEmpty, onConfirm: apply) {
            TextField("New tag (use / to nest, e.g. Travel/Japan)", text: $newTag).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("new-tag")
            List(tags, id: \.id) { tag in
                Toggle(tag.value, isOn: Binding(get: { chosen.contains(tag.id) },
                                                set: { if $0 { chosen.insert(tag.id) } else { chosen.remove(tag.id) } }))
            }
            .frame(width: 360, height: 240)
        }
        .task {
            tags = ((try? await library.client.getAllTags()) ?? [])
                .filter { !$0.value.hasPrefix("Culling/") }
                .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        }
    }

    private func apply() {
        let ids = ids, chosen = Array(chosen)
        let typed = newTag.trimmingCharacters(in: .whitespaces)
        library.perform("Add Tags", ids: ids, change: .metadata(ids: ids), rewritesFiles: true) { actions in
            var tagIDs = chosen
            if !typed.isEmpty, let leaf = try await actions.client.upsertTags(body: TagUpsertDto(tags: [typed])).first(where: { $0.value == typed }) {
                tagIDs.append(leaf.id)
            }
            return try await actions.tag(ids, tagIDs: tagIDs)
        }
    }
}

// MARK: Geotag

/// Click the map (or search for a place) to set the location of the selected photos.
struct GeotagSheet: View {
    @EnvironmentObject var library: LibraryModel
    let ids: [String]
    @State private var position: MapCameraPosition = .automatic
    @State private var pin: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        SheetFrame(title: "Set Location", subtitle: "\(itemsLabel(ids.count)) · click the map to drop a pin",
                   confirm: "Set Location", confirmDisabled: pin == nil, onConfirm: apply) {
            HStack {
                TextField("Search for a place", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                    .accessibilityIdentifier("geotag-search")
                Button("Search", action: search)
            }
            if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(results, id: \.self) { item in
                            Button(item.name ?? "Place") { choose(item.location.coordinate) }
                        }
                    }
                }
            }
            MapReader { proxy in
                Map(position: $position) {
                    if let pin { Marker("", coordinate: pin).tint(.orange) }
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) { pin = coordinate }
                }
            }
            .frame(width: 560, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("geotag-map")
            if let pin {
                Text(String(format: "%.5f, %.5f", pin.latitude, pin.longitude)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .task {
            // Start from the photo's current location if it has one.
            if let id = ids.first, let info = try? await library.client.getAssetInfo(id: id),
               let lat = info.exifInfo?.latitude, let lon = info.exifInfo?.longitude {
                choose(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
    }

    private func choose(_ coordinate: CLLocationCoordinate2D) {
        pin = coordinate
        position = .region(MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
    }

    private func search() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            results = Array((response?.mapItems ?? []).prefix(6))
            if let first = results.first { choose(first.location.coordinate) }
        }
    }

    private func apply() {
        guard let pin else { return }
        library.setLocation(latitude: pin.latitude, longitude: pin.longitude, ids: ids)
    }
}
