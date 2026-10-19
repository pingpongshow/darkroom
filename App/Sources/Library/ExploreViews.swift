import SwiftUI
import ImmichAPI
import DarkRoomCore

/// Circular face thumbnail for a recognised person.
struct FaceView: View {
    @EnvironmentObject var library: LibraryModel
    let person: PersonResponseDto
    var size: CGFloat = 96
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Circle().fill(Theme.panelRaised)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: "\(person.id)-\(person.updatedAt ?? "")") {
            image = try? await library.pipeline.faceImage(personID: person.id, version: person.updatedAt, maxPixel: Int(size * 2))
        }
    }
}

/// Loads and edits the signed-in user's people (rename, favourite, hide, merge).
@MainActor
final class PeopleModel: ObservableObject {
    @Published var people: [PersonResponseDto] = []
    @Published var hiddenCount = 0
    @Published var isLoading = false
    @Published var error: String?

    func load(_ client: ImmichClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var all: [PersonResponseDto] = []
            var page = 1
            while true {
                let response = try await client.getAllPeople(page: page, size: 500, withHidden: true)
                all += response.people
                hiddenCount = response.hidden
                guard response.hasNextPage == true else { break }
                page += 1
            }
            people = all
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func update(_ id: String, _ change: PersonUpdateDto, client: ImmichClient) async {
        do {
            let updated = try await client.updatePerson(id: id, body: change)
            if let index = people.firstIndex(where: { $0.id == id }) { people[index] = updated }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Merges `others` into `target` (Immich moves their faces and deletes the merged people).
    func merge(_ others: [String], into target: String, client: ImmichClient) async {
        do {
            _ = try await client.mergePersonLegacy(id: target, body: MergePersonDto(ids: others))
            people.removeAll { others.contains($0.id) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PeopleView: View {
    @EnvironmentObject var library: LibraryModel
    @StateObject private var model = PeopleModel()
    @State private var filter = ""
    @State private var showHidden = false
    @State private var renaming: PersonResponseDto?
    @State private var newName = ""
    @State private var merging: PersonResponseDto?
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter people", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
                    .accessibilityIdentifier("people-filter")
                Toggle("Show hidden people", isOn: $showHidden).toggleStyle(.checkbox)
                    .accessibilityIdentifier("people-show-hidden")
                Spacer()
                Text("Right-click a person to hide, rename or merge").font(.caption).foregroundStyle(Theme.textTertiary)
                Text("\(visible.count) people").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            ScrollView {
                if visible.isEmpty && !model.isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textTertiary)
                        Text(model.error ?? "No people yet. Immich finds faces after its machine-learning jobs run.")
                            .foregroundStyle(model.error == nil ? Theme.textSecondary : Theme.danger)
                            .multilineTextAlignment(.center)
                    }
                    .padding(60)
                    .accessibilityIdentifier("people-empty")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 18)], spacing: 18) {
                    ForEach(visible, id: \.id) { person in
                        ZStack(alignment: .topLeading) {
                            Button { open(person) } label: {
                                VStack(spacing: 6) {
                                    FaceView(person: person, size: 104)
                                        .opacity(person.isHidden ? 0.4 : 1)
                                        .overlay(alignment: .topTrailing) {
                                            if person.isFavorite == true { Image(systemName: "heart.fill").foregroundStyle(.white).padding(4) }
                                        }
                                    Text(person.name.isEmpty ? "Add name" : person.name)
                                        .foregroundStyle(person.name.isEmpty ? Theme.textTertiary : Theme.text)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("person-\(person.id)")
                            .contextMenu { menu(person) }
                            if hovered == person.id || person.isHidden {
                                HideFaceButton(person: person) { hide(person) }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .onHover { inside in
                            if inside { hovered = person.id } else if hovered == person.id { hovered = nil }
                        }
                    }
                }
                .padding(18)
            }
        }
        .background(Theme.gridBackground)
        .task { await model.load(library.client); remember() }
        .sheet(item: $renaming) { person in
            RenameSheet(title: "Name this person", name: $newName) { name in
                Task { await model.update(person.id, PersonUpdateDto(name: name), client: library.client); remember() }
            }
        }
        .sheet(item: $merging) { person in
            MergePeopleSheet(target: person, candidates: model.people.filter { $0.id != person.id }) { ids in
                Task { await model.merge(ids, into: person.id, client: library.client) }
            }
        }
    }

    private var visible: [PersonResponseDto] {
        model.people
            .filter { showHidden || !$0.isHidden }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { lhs, rhs in
                if (lhs.isFavorite == true) != (rhs.isFavorite == true) { return lhs.isFavorite == true }
                if lhs.name.isEmpty != rhs.name.isEmpty { return !lhs.name.isEmpty }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func hide(_ person: PersonResponseDto) {
        Task { await model.update(person.id, PersonUpdateDto(isHidden: !person.isHidden), client: library.client) }
    }

    private func remember() {
        for person in model.people { library.personNames[person.id] = person.name }
    }

    private func open(_ person: PersonResponseDto) {
        library.personNames[person.id] = person.name
        library.destination = .person(person.id)
    }

    @ViewBuilder private func menu(_ person: PersonResponseDto) -> some View {
        Button("Rename…") { newName = person.name; renaming = person }
        Button(person.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
            Task { await model.update(person.id, PersonUpdateDto(isFavorite: !(person.isFavorite ?? false)), client: library.client) }
        }
        Button(person.isHidden ? "Show in People" : "Hide from People") {
            Task { await model.update(person.id, PersonUpdateDto(isHidden: !person.isHidden), client: library.client) }
        }
        Divider()
        Button("Merge Others into \(person.name.isEmpty ? "This Person" : person.name)…") { merging = person }
    }
}

extension PersonResponseDto: @retroactive Identifiable {}

/// Hover button on a face: hide the person (or show them again when hidden people are listed).
private struct HideFaceButton: View {
    let person: PersonResponseDto
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: person.isHidden ? "eye" : "eye.slash")
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(5).background(Circle().fill(.black.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .padding(2)
        .help(person.isHidden ? "Show this person in People again" : "Hide this person from People (also in Immich)")
        .accessibilityIdentifier("hide-person-\(person.id)")
    }
}

struct RenameSheet: View {
    let title: String
    @Binding var name: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit(save)
                .accessibilityIdentifier("rename-field")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).accessibilityIdentifier("rename-save")
            }
        }
        .padding(20)
    }

    private func save() {
        onSave(name.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

struct MergePeopleSheet: View {
    let target: PersonResponseDto
    let candidates: [PersonResponseDto]
    var onMerge: ([String]) -> Void
    @State private var chosen: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge into \(target.name.isEmpty ? "this person" : target.name)").font(.headline)
            Text("The faces of the people you choose move to this person.").foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                    ForEach(candidates, id: \.id) { person in
                        Button {
                            if chosen.contains(person.id) { chosen.remove(person.id) } else { chosen.insert(person.id) }
                        } label: {
                            VStack {
                                FaceView(person: person, size: 60)
                                    .overlay(Circle().stroke(chosen.contains(person.id) ? Theme.highlight : .clear, lineWidth: 3))
                                Text(person.name.isEmpty ? "Unnamed" : person.name).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 420, height: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge \(chosen.count)") { onMerge(Array(chosen)); dismiss() }
                    .disabled(chosen.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

/// Places: one tile per city (Immich picks a representative photo).
struct PlacesView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var places: [AssetResponseDto] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            if loaded && places.isEmpty {
                Text(error ?? "No places yet. Photos with a location appear here.")
                    .foregroundStyle(error == nil ? Theme.textSecondary : Theme.danger).padding(60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(places, id: \.id) { asset in
                    PlaceTile(asset: asset) { open(asset) }
                }
            }
            .padding(18)
        }
        .background(Theme.gridBackground)
        .task {
            do {
                places = try await library.client.getAssetsByCity()
                    .sorted { ($0.exifInfo?.city ?? "") < ($1.exifInfo?.city ?? "") }
            } catch { self.error = error.localizedDescription }
            loaded = true
        }
    }

    private func open(_ asset: AssetResponseDto) {
        var query = SearchQuery()
        query.city = asset.exifInfo?.city
        query.country = asset.exifInfo?.country
        library.search(query)
    }
}

struct PlaceTile: View {
    let asset: AssetResponseDto
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .overlay { PipelineImage(asset: TimelineAsset(asset), size: .thumbnail, maxPixel: 400) }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(asset.exifInfo?.city ?? "Unknown").font(.headline)
                        if let country = asset.exifInfo?.country { Text(country).font(.caption) }
                    }
                    .foregroundStyle(.white).shadow(radius: 3).padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("place-\(asset.exifInfo?.city ?? asset.id)")
    }
}

/// Explore: people, places, cameras and quick collections.
struct ExploreView: View {
    @EnvironmentObject var library: LibraryModel
    @StateObject private var people = PeopleModel()
    @State private var places: [AssetResponseDto] = []
    @State private var cameras: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("People", seeAll: { library.destination = .people }) {
                    if namedPeople.isEmpty {
                        Text("No people yet").foregroundStyle(Theme.textTertiary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(namedPeople.prefix(20), id: \.id) { person in
                                    Button {
                                        library.personNames[person.id] = person.name
                                        library.destination = .person(person.id)
                                    } label: {
                                        VStack(spacing: 4) {
                                            FaceView(person: person, size: 84)
                                            Text(person.name.isEmpty ? "Unnamed" : person.name).font(.caption).lineLimit(1)
                                        }
                                        .frame(width: 92)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                section("Places", seeAll: { library.destination = .places }) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(places.prefix(20), id: \.id) { asset in
                                PlaceTile(asset: asset) {
                                    var query = SearchQuery()
                                    query.city = asset.exifInfo?.city
                                    query.country = asset.exifInfo?.country
                                    library.search(query)
                                }
                                .frame(width: 180)
                            }
                        }
                    }
                }
                section("Collections") {
                    FlowLayout(spacing: 10) {
                        chip("Videos", "video") { var q = SearchQuery(); q.mediaType = .videos; library.search(q) }
                        chip("Favorites", "heart") { library.destination = .favorites }
                        chip("Five stars", "star") { var q = SearchQuery(); q.minimumRating = 5; library.search(q) }
                        chip("Not in an album", "rectangle.stack.badge.minus") { var q = SearchQuery(); q.notInAnyAlbum = true; library.search(q) }
                        chip("Map", "map") { library.destination = .map }
                    }
                }
                if !cameras.isEmpty {
                    section("Cameras") {
                        FlowLayout(spacing: 8) {
                            ForEach(cameras, id: \.self) { make in
                                chip(make, "camera") { var q = SearchQuery(); q.make = make; library.search(q) }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.gridBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore")
        .task {
            async let p: Void = people.load(library.client)
            places = (try? await library.client.getAssetsByCity()) ?? []
            cameras = ((try? await library.client.getSearchSuggestions(type: .cameraMake)) ?? []).sorted()
            await p
            for person in people.people { library.personNames[person.id] = person.name }
        }
    }

    private var namedPeople: [PersonResponseDto] {
        people.people.filter { !$0.isHidden }.sorted { !$0.name.isEmpty && $1.name.isEmpty }
    }

    private func section<Content: View>(_ title: String, seeAll: (() -> Void)? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.weight(.medium)).foregroundStyle(Theme.text)
                Spacer()
                if let seeAll { Button("See All", action: seeAll).buttonStyle(.link) }
            }
            content()
        }
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Theme.panelRaised))
                .foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("explore-\(title)")
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
