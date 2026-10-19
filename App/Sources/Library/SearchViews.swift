import SwiftUI
import AppKit
import ImmichAPI
import DarkRoomCore

/// Toolbar search: natural-language text plus a filter popover (⌘F focuses it).
struct SearchField: View {
    @EnvironmentObject var library: LibraryModel
    @State private var showFilters = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $library.searchDraft.text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    library.search(library.searchDraft)
                    // Hand the keyboard back to the grid so G / E / D and the arrows work again.
                    DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
                }
                .accessibilityIdentifier("search-field")
            if !library.searchDraft.isEmpty {
                Button { library.search(SearchQuery()) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.textTertiary).help("Clear search")
                    .accessibilityIdentifier("search-clear")
            }
            Button { showFilters.toggle() } label: {
                Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(hasFilters ? Theme.highlight : Theme.textSecondary)
            .help("Search filters")
            .accessibilityIdentifier("search-filters")
            .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                SearchFiltersView(onSearch: { showFilters = false })
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
        .frame(width: 260)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focused = true }
    }

    private var placeholder: String {
        switch library.searchDraft.textMode {
        case .smart: "Search “sunset at the beach”"
        case .fileName: "File name"
        case .description: "Description"
        case .ocr: "Text in photo"
        }
    }

    private var hasFilters: Bool {
        var withoutText = library.searchDraft
        withoutText.text = ""
        withoutText.textMode = .smart
        return !withoutText.isEmpty
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("DarkRoom.focusSearch")
}

/// Metadata filters, populated from Immich's search suggestions.
struct SearchFiltersView: View {
    @EnvironmentObject var library: LibraryModel
    var onSearch: () -> Void
    @State private var countries: [String] = []
    @State private var states: [String] = []
    @State private var cities: [String] = []
    @State private var makes: [String] = []
    @State private var models: [String] = []
    @State private var lenses: [String] = []
    @State private var people: [PersonResponseDto] = []

    private var query: Binding<SearchQuery> { $library.searchDraft }

    var body: some View {
        Form {
            Section("Text") {
                Picker("Match", selection: query.textMode) {
                    Text("Smart search").tag(SearchQuery.TextMode.smart)
                    Text("File name").tag(SearchQuery.TextMode.fileName)
                    Text("Description").tag(SearchQuery.TextMode.description)
                    Text("Text in photo").tag(SearchQuery.TextMode.ocr)
                }
                .accessibilityIdentifier("filter-text-mode")
            }
            Section("Media") {
                Picker("Type", selection: query.mediaType) {
                    Text("All").tag(SearchQuery.MediaType.all)
                    Text("Photos").tag(SearchQuery.MediaType.photos)
                    Text("Videos").tag(SearchQuery.MediaType.videos)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("filter-media")
                Toggle("Favorites only", isOn: query.favoritesOnly).accessibilityIdentifier("filter-favorites")
                Picker("Rating", selection: query.minimumRating) {
                    Text("Any").tag(Int?.none)
                    ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag(Int?.some($0)) }
                }
                Toggle("Include archived", isOn: query.includeArchived)
                Toggle("Not in any album", isOn: query.notInAnyAlbum)
            }
            Section("Place") {
                suggestionPicker("Country", values: countries, selection: query.country)
                suggestionPicker("State", values: states, selection: query.state)
                suggestionPicker("City", values: cities, selection: query.city)
            }
            Section("Camera") {
                suggestionPicker("Make", values: makes, selection: query.make)
                suggestionPicker("Model", values: models, selection: query.model)
                suggestionPicker("Lens", values: lenses, selection: query.lensModel)
            }
            Section("Date taken") {
                optionalDate("From", query.takenAfter)
                optionalDate("To", query.takenBefore)
            }
            if !people.isEmpty {
                Section("People") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(people, id: \.id) { person in
                                let selected = library.searchDraft.personIDs.contains(person.id)
                                Button {
                                    if selected { library.searchDraft.personIDs.removeAll { $0 == person.id } }
                                    else { library.searchDraft.personIDs.append(person.id) }
                                } label: {
                                    VStack(spacing: 3) {
                                        FaceView(person: person, size: 44)
                                            .overlay(Circle().stroke(selected ? Theme.highlight : .clear, lineWidth: 2))
                                        Text(person.name.isEmpty ? "Unnamed" : person.name).font(.caption2).lineLimit(1)
                                    }
                                    .frame(width: 58)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 560)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Reset") { library.searchDraft = SearchQuery(text: library.searchDraft.text) }
                Spacer()
                Button("Search") { library.search(library.searchDraft); onSearch() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("filter-search")
            }
            .padding(12)
        }
        .task { await loadSuggestions() }
        .onChange(of: library.searchDraft.country) { Task { await loadSuggestions() } }
        .onChange(of: library.searchDraft.make) { Task { await loadSuggestions() } }
    }

    private func suggestionPicker(_ title: String, values: [String], selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(String?.none)
            ForEach(values, id: \.self) { Text($0).tag(String?.some($0)) }
            if let current = selection.wrappedValue, !values.contains(current) { Text(current).tag(String?.some(current)) }
        }
    }

    private func optionalDate(_ title: String, _ binding: Binding<Date?>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { binding.wrappedValue != nil },
                                        set: { binding.wrappedValue = $0 ? (binding.wrappedValue ?? .now) : nil }))
            if binding.wrappedValue != nil {
                DatePicker("", selection: Binding(get: { binding.wrappedValue ?? .now }, set: { binding.wrappedValue = $0 }),
                           displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }

    private func loadSuggestions() async {
        let client = library.client
        let q = library.searchDraft
        async let c = client.getSearchSuggestions(type: .country)
        async let s = client.getSearchSuggestions(country: q.country, type: .state)
        async let ci = client.getSearchSuggestions(country: q.country, state: q.state, type: .city)
        async let mk = client.getSearchSuggestions(type: .cameraMake)
        async let md = client.getSearchSuggestions(make: q.make, type: .cameraModel)
        async let ln = client.getSearchSuggestions(make: q.make, model: q.model, type: .cameraLensModel)
        async let p = client.getAllPeople(size: 200)
        countries = ((try? await c) ?? []).sorted()
        states = ((try? await s) ?? []).sorted()
        cities = ((try? await ci) ?? []).sorted()
        makes = ((try? await mk) ?? []).sorted()
        models = ((try? await md) ?? []).sorted()
        lenses = ((try? await ln) ?? []).sorted()
        people = ((try? await p)?.people ?? []).filter { !$0.isHidden }
    }
}
