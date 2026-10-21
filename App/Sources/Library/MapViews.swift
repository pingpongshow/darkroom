import SwiftUI
import MapKit
import ImmichAPI
import DarkRoomCore

/// Library map: every geotagged photo, grouped into clusters for the visible area. Click a cluster or pin to see
/// its photos; "Photos in View" shows everything in the visible area.
struct LibraryMapView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var markers: [MapMarkerResponseDto] = []
    @State private var markersVersion = 0
    @State private var visibleIDs: [String] = []
    @State private var error: String?
    @State private var loaded = false
    @AppStorage("mapStyle", store: .darkRoom) private var style = "standard"

    var body: some View {
        ZStack(alignment: .top) {
            ClusteredMap(markers: markers, version: markersVersion, style: style,
                         onSelect: { ids, title in
                             library.destination = .mapSelection(MapSelection(title: title, assetIDs: ids))
                         },
                         onVisibleChange: { visibleIDs = $0 })
                .accessibilityIdentifier("library-map")
            HStack {
                Picker("", selection: $style) {
                    Text("Map").tag("standard")
                    Text("Satellite").tag("hybrid")
                }
                .pickerStyle(.segmented).frame(width: 160)
                Spacer()
                if loaded {
                    Text("\(markers.count) geotagged").font(.caption).foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("map-count")
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Photos in View (\(visibleIDs.count))") {
                    library.destination = .mapSelection(MapSelection(title: "Photos in View", assetIDs: visibleIDs))
                }
                .disabled(visibleIDs.isEmpty)
                .accessibilityIdentifier("map-photos-in-view")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
            if let error {
                Text(error).foregroundStyle(Theme.danger).padding().background(.regularMaterial).padding(.top, 70)
            }
        }
        .task {
            // Show the markers from the last visit at once, then refresh them.
            if let cached = library.mapMarkers {
                markers = cached
                markersVersion += 1
                loaded = true
            }
            do {
                let fresh = try await library.client.getMapMarkers(isArchived: false, withPartners: true)
                library.mapMarkers = fresh
                if fresh != markers {
                    markers = fresh
                    markersVersion += 1
                }
            } catch is CancellationError {
            } catch {
                if library.mapMarkers == nil { self.error = error.localizedDescription }
            }
            loaded = true
        }
    }
}

/// A pin for one photo or a group of nearby photos.
final class PhotoGroupAnnotation: NSObject, MKAnnotation {
    let key: String
    let ids: [String]
    let place: String?
    let coordinate: CLLocationCoordinate2D
    init(key: String, ids: [String], place: String?, coordinate: CLLocationCoordinate2D) {
        self.key = key; self.ids = ids; self.place = place; self.coordinate = coordinate
    }
    var title: String? { place ?? "\(ids.count) photos" }
    var selectionTitle: String { place ?? "\(ids.count) photos on the map" }
}

struct ClusteredMap: NSViewRepresentable {
    var markers: [MapMarkerResponseDto]
    /// Bumped when `markers` changes (cheaper than comparing the whole list on every update).
    var version: Int
    var style: String
    var onSelect: ([String], String) -> Void
    var onVisibleChange: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsZoomControls = true
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "photo")
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let type: MKMapType = style == "hybrid" ? .hybrid : .standard
        if map.mapType != type { map.mapType = type }
        guard version != coordinator.version else { return }
        let first = coordinator.points.isEmpty
        coordinator.version = version
        coordinator.points = markers.map {
            Coordinator.Point(id: $0.id, map: MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)),
                              place: $0.city ?? $0.state ?? $0.country)
        }
        if first, let bounds = coordinator.bounds() {
            map.setVisibleMapRect(bounds, edgePadding: NSEdgeInsets(top: 80, left: 40, bottom: 40, right: 40), animated: false)
        }
        coordinator.recluster(map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        struct Point: Sendable {
            let id: String
            let map: MKMapPoint
            let place: String?
        }

        struct Group: Sendable {
            let key: String
            let ids: [String]
            let place: String?
            let center: MKMapPoint
        }

        var parent: ClusteredMap
        var version = -1
        var points: [Point] = []
        private var task: Task<Void, Never>?
        private var shown: [String: PhotoGroupAnnotation] = [:]
        init(_ parent: ClusteredMap) { self.parent = parent }

        /// Smallest map rect around every photo.
        func bounds() -> MKMapRect? {
            guard let first = points.first else { return nil }
            var minX = first.map.x, maxX = minX, minY = first.map.y, maxY = minY
            for p in points {
                minX = min(minX, p.map.x); maxX = max(maxX, p.map.x)
                minY = min(minY, p.map.y); maxY = max(maxY, p.map.y)
            }
            let pad = 2000.0   // a single photo still gets a sensible zoom
            return MKMapRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
        }

        /// Groups the photos in view into screen cells (~70 pt) off the main thread, then swaps the pins that changed.
        func recluster(_ map: MKMapView) {
            let visible = map.visibleMapRect
            let width = map.bounds.width
            guard width > 0, !visible.isNull, visible.width > 0 else { return }
            let cell = visible.width / Double(width) * 70
            let points = self.points
            task?.cancel()
            task = Task { [weak self, weak map] in
                let (groups, inView) = await Task.detached(priority: .userInitiated) {
                    Self.cluster(points, in: visible, cell: cell)
                }.value
                guard let self, let map, !Task.isCancelled else { return }
                self.show(groups, on: map)
                self.parent.onVisibleChange(inView)
            }
        }

        nonisolated static func cluster(_ points: [Point], in visible: MKMapRect, cell: Double) -> ([Group], [String]) {
            let world = MKMapRect.world.width
            // Include a margin so pins at the edges don't pop in while panning.
            let area = visible.insetBy(dx: -visible.width * 0.25, dy: -visible.height * 0.25)
            struct Bucket { var ids: [String] = []; var x = 0.0; var y = 0.0; var place: String?; var mixed = false }
            var buckets: [Int64: Bucket] = [:]
            var inView: [String] = []
            for p in points {
                // Views can cross the 180° meridian, where map x wraps around.
                var point = p.map
                if !area.contains(point) {
                    let wrapped = MKMapPoint(x: point.x + world, y: point.y)
                    guard area.contains(wrapped) else { continue }
                    point = wrapped
                }
                if visible.contains(point) { inView.append(p.id) }
                let key = Int64(floor(point.x / cell)) << 32 ^ Int64(floor(point.y / cell))
                var bucket = buckets[key] ?? Bucket()
                if bucket.ids.isEmpty { bucket.place = p.place } else if bucket.place != p.place { bucket.mixed = true }
                bucket.ids.append(p.id)
                bucket.x += point.x; bucket.y += point.y
                buckets[key] = bucket
            }
            let groups = buckets.map { key, b in
                Group(key: "\(key)-\(b.ids.count)-\(b.ids[0])", ids: b.ids, place: b.mixed ? nil : (b.place ?? (b.ids.count == 1 ? "Photo" : nil)),
                      center: MKMapPoint(x: b.x / Double(b.ids.count), y: b.y / Double(b.ids.count)))
            }
            return (groups, inView)
        }

        private func show(_ groups: [Group], on map: MKMapView) {
            var next: [String: PhotoGroupAnnotation] = [:]
            var added: [PhotoGroupAnnotation] = []
            for group in groups {
                if let existing = shown[group.key] { next[group.key] = existing; continue }
                let annotation = PhotoGroupAnnotation(key: group.key, ids: group.ids, place: group.place, coordinate: group.center.coordinate)
                next[group.key] = annotation
                added.append(annotation)
            }
            let removed = shown.filter { next[$0.key] == nil }.map(\.value)
            map.removeAnnotations(removed)
            map.addAnnotations(added)
            shown = next
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let group = annotation as? PhotoGroupAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "photo", for: annotation) as! MKMarkerAnnotationView
            view.markerTintColor = .systemOrange
            view.displayPriority = .required
            if group.ids.count == 1 {
                view.glyphText = nil
                view.glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            } else {
                view.glyphImage = nil
                view.glyphText = group.ids.count >= 1000 ? "\(group.ids.count / 1000)k" : "\(group.ids.count)"
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let group = view.annotation as? PhotoGroupAnnotation else { return }
            mapView.deselectAnnotation(group, animated: false)
            parent.onSelect(group.ids, group.selectionTitle)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { recluster(mapView) }
    }
}
