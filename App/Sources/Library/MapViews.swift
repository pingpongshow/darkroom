import SwiftUI
import MapKit
import ImmichAPI
import DarkRoomCore

/// Library map: every geotagged photo as a clustered pin. Click a cluster or pin to see its photos;
/// "Photos in View" shows everything in the visible area.
struct LibraryMapView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var markers: [MapMarkerResponseDto] = []
    @State private var visibleIDs: [String] = []
    @State private var error: String?
    @State private var loaded = false
    @AppStorage("mapStyle", store: .darkRoom) private var style = "standard"

    var body: some View {
        ZStack(alignment: .top) {
            ClusteredMap(markers: markers, style: style,
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
            do { markers = try await library.client.getMapMarkers(isArchived: false, withPartners: true) }
            catch { self.error = error.localizedDescription }
            loaded = true
        }
    }
}

final class PhotoAnnotation: NSObject, MKAnnotation {
    let id: String
    let place: String
    let coordinate: CLLocationCoordinate2D
    init(_ marker: MapMarkerResponseDto) {
        id = marker.id
        place = marker.city ?? marker.state ?? marker.country ?? "Photo"
        coordinate = CLLocationCoordinate2D(latitude: marker.lat, longitude: marker.lon)
    }
    var title: String? { place }
}

struct ClusteredMap: NSViewRepresentable {
    var markers: [MapMarkerResponseDto]
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
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        map.mapType = style == "hybrid" ? .hybrid : .standard
        let ids = Set(markers.map(\.id))
        guard ids != context.coordinator.shownIDs else { return }
        context.coordinator.shownIDs = ids
        map.removeAnnotations(map.annotations)
        let annotations = markers.map(PhotoAnnotation.init)
        map.addAnnotations(annotations)
        if !annotations.isEmpty { map.showAnnotations(annotations, animated: false) }
        context.coordinator.reportVisible(map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ClusteredMap
        var shownIDs: Set<String> = []
        init(_ parent: ClusteredMap) { self.parent = parent }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                                                                 for: cluster) as! MKMarkerAnnotationView
                view.markerTintColor = .systemOrange
                view.glyphText = "\(cluster.memberAnnotations.count)"
                return view
            }
            guard annotation is PhotoAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "photo", for: annotation) as! MKMarkerAnnotationView
            view.clusteringIdentifier = "photos"
            view.markerTintColor = .systemOrange
            view.glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            view.displayPriority = .defaultHigh
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            if let cluster = annotation as? MKClusterAnnotation {
                let photos = cluster.memberAnnotations.compactMap { $0 as? PhotoAnnotation }
                let places = Set(photos.map(\.place))
                parent.onSelect(photos.map(\.id), places.count == 1 ? places.first! : "\(photos.count) photos on the map")
            } else if let photo = annotation as? PhotoAnnotation {
                parent.onSelect([photo.id], photo.place)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { reportVisible(mapView) }

        func reportVisible(_ map: MKMapView) {
            let region = map.region
            guard region.span.latitudeDelta > 0 else { return }
            let ids = parent.markers.filter { Self.contains(region, lat: $0.lat, lon: $0.lon) }.map(\.id)
            let report = parent.onVisibleChange
            DispatchQueue.main.async { report(ids) }
        }

        /// Region test that handles views spanning the 180° meridian.
        nonisolated static func contains(_ region: MKCoordinateRegion, lat: Double, lon: Double) -> Bool {
            guard abs(lat - region.center.latitude) <= region.span.latitudeDelta / 2 else { return false }
            if region.span.longitudeDelta >= 360 { return true }
            let diff = abs((lon - region.center.longitude + 540).truncatingRemainder(dividingBy: 360) - 180)
            return diff <= region.span.longitudeDelta / 2
        }
    }
}
