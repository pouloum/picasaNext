import MapKit
import PicasaCore
import SwiftUI

/// Places: geotagged photos on an Apple map, grouped into pins that are re-clustered for the current
/// zoom (so 100k+ photos stay fluid). Clicking a pin lists its photos; otherwise the side panel lists
/// the photos in view.
struct PlacesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var points: [GeoPoint] = []
    @State private var clusters: [GeoCluster] = []
    @State private var selected: GeoCluster?
    @State private var visibleIds: [Int64] = []
    /// Starts on France, never `.automatic`: an automatic camera fits every annotation, so while the
    /// clusters arrive it zooms out to the whole world as soon as one photo was taken abroad.
    @State private var position: MapCameraPosition = .region(PlacesView.france)
    @State private var region: MKCoordinateRegion?
    @State private var loaded = false
    @State private var clusterTask: Task<Void, Never>?
    @State private var camera: MapCamera?
    /// Map style: standard, satellite imagery, or hybrid (imagery + roads and names); optional relief.
    @AppStorage("places.style") private var style = "standard"
    @AppStorage("places.relief") private var relief = false
    @State private var year = 0 // 0 = all years
    /// The camera was put on a place by a link: the first load must not fit everything instead.
    @State private var centred = false
    @State private var geoCells = (named: 0, unnamed: 0)

    var years: [Int] { Array(Set(points.map(\.year).filter { $0 > 0 })).sorted(by: >) }
    var shownPoints: [GeoPoint] { year == 0 ? points : points.filter { $0.year == year } }

    /// Side panel cap: enough to browse, small enough to stay instant on huge regions.
    private let panelLimit = 5000

    var panelIds: [Int64] { selected?.ids ?? visibleIds }

    var body: some View {
        Group {
            if loaded && points.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "map",
                                       description: Text("No photo has GPS coordinates (from the camera or imported from Picasa)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    // Same zoom range in every style: satellite otherwise stops zooming much earlier
                    // than the map (MapKit's own limit for imagery), though it can show closer views.
                    Map(position: $position, bounds: MapCameraBounds(minimumDistance: 40)) {
                        ForEach(clusters) { c in
                            Annotation("", coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)) {
                                // Map annotations are hosted outside this view tree: pass the model explicitly.
                                ClusterPin(cluster: c, selected: selected?.id == c.id).environmentObject(model)
                                    .onTapGesture { selected = selected?.id == c.id ? nil : c }
                            }
                        }
                    }
                    .mapStyle(mapStyle)
                    .overlay(alignment: .topTrailing) { stylePicker.padding(10) }
                    .overlay(alignment: .bottomTrailing) { zoomButtons.padding(10) }
                    .onMapCameraChange(frequency: .continuous) { ctx in camera = ctx.camera }
                    .onMapCameraChange(frequency: .onEnd) { ctx in
                        camera = ctx.camera
                        region = ctx.region
                        recluster()
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(selected.map { "\($0.count) photo\($0.count > 1 ? "s" : "") here" } ?? "\(visibleIds.count) photos in view")
                                .font(.headline)
                            Spacer()
                            if selected != nil {
                                Button("All in view") { selected = nil }
                            }
                        }
                        .padding(10)
                        if panelIds.isEmpty {
                            Text("Move or zoom the map to see photos.").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            CollectionGrid(ids: panelIds, cellSize: 104, thumbs: model.thumbs, resetKey: selected?.id ?? "view", revision: model.revision) { model.open(panelIds, at: $0) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 360)
                }
            }
        }
        .onChange(of: model.openPlace) { centre(on: model.openPlace) }
        .task(id: model.revision) {
            let first = !loaded
            points = (try? await model.library.geoPoints()) ?? []
            geoCells = (try? await model.library.geoCellCounts()) ?? (0, 0)
            loaded = true
            // Live updates (scan running) re-cluster in place; only the first load moves the camera —
            // unless a link asked for a place (then the camera is already there: keep it).
            if let p = model.openPlace { centre(on: p) }
            else if centred { recluster() }
            else if first || region == nil { fitAll() } else { recluster() } // first load: France
        }
    }

    /// A link (info panel) asked for a place: zoom there (about 2 km across).
    func centre(on p: GeoPoint?) {
        guard let p else { return }
        model.openPlace = nil
        centred = true
        // Close in: about 250 m across, the photo's pin in the middle.
        let c = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
        position = .camera(MapCamera(centerCoordinate: c, distance: 350))
        region = MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.0025, longitudeDelta: 0.0025))
        recluster()
    }

    /// Initial camera: metropolitan France, whatever the spread of the photos (fitting every
    /// geotagged photo zoomed out to the whole world as soon as one was taken abroad).
    static let france = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.4),
                                           span: MKCoordinateSpan(latitudeDelta: 10.5, longitudeDelta: 13))

    func fitAll() {
        let r = Self.france
        position = .region(r)
        region = r
        recluster()
    }

    var mapStyle: MapStyle {
        let elevation: MapStyle.Elevation = relief ? .realistic : .flat
        switch style {
        case "satellite": return .imagery(elevation: elevation)
        case "hybrid": return .hybrid(elevation: elevation, pointsOfInterest: .excludingAll)
        default: return .standard(elevation: elevation, pointsOfInterest: .excludingAll)
        }
    }

    var stylePicker: some View {
        HStack(spacing: 8) {
            Picker("", selection: $year) {
                Text("All years").tag(0)
                Divider()
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            .onChange(of: year) { selected = nil; recluster() }
            if geoCells.unnamed > 0 && model.job == nil {
                Button { model.geocode() } label: { Label("Name places", systemImage: "mappin.and.ellipse") }
                    .help("Look up the town of \(geoCells.unnamed) areas with photos (Apple's geocoder, network needed; slow, resumable)")
            }
            Picker("", selection: $style) {
                Text("Map").tag("standard")
                Text("Satellite").tag("satellite")
                Text("Hybrid").tag("hybrid")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("3D", isOn: $relief).toggleStyle(.button).help("Relief and 3D buildings (tilt with ⌥-drag or two fingers)")
        }
        .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Zoom buttons: they move the camera directly, which also goes past the pinch limit of satellite views.
    var zoomButtons: some View {
        VStack(spacing: 0) {
            Button { zoom(by: 0.5) } label: { Image(systemName: "plus").frame(width: 28, height: 26) }
            Divider().frame(width: 28)
            Button { zoom(by: 2) } label: { Image(systemName: "minus").frame(width: 28, height: 26) }
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .help("Zoom (also past the satellite pinch limit)")
    }

    func zoom(by factor: Double) {
        guard var c = camera else { return }
        c.distance = max(40, c.distance * factor)
        withAnimation(.easeInOut(duration: 0.3)) { position = .camera(c) }
    }

    /// Pins for the visible area, computed off the main thread (tens of thousands of points).
    func recluster() {
        guard let r = region else { return }
        let lat = (r.center.latitude - r.span.latitudeDelta / 2)...(r.center.latitude + r.span.latitudeDelta / 2)
        let lon = (r.center.longitude - r.span.longitudeDelta / 2)...(r.center.longitude + r.span.longitudeDelta / 2)
        let pts = shownPoints, limit = panelLimit
        clusterTask?.cancel()
        clusterTask = Task {
            let (c, inView) = await Task.detached(priority: .userInitiated) { () -> ([GeoCluster], [Int64]) in
                let c = GeoCluster.cluster(pts, latRange: lat, lonRange: lon)
                var inView: [Int64] = []
                for p in pts where lat.contains(p.lat) && lon.contains(p.lon) {
                    inView.append(p.id)
                    if inView.count >= limit { break }
                }
                return (c, inView)
            }.value
            guard !Task.isCancelled else { return }
            clusters = c
            visibleIds = inView
            if let s = selected { selected = c.first { $0.id == s.id } ?? s }
        }
    }
}

/// A map pin: the cluster's best photo with its photo count.
struct ClusterPin: View {
    let cluster: GeoCluster
    let selected: Bool

    var body: some View {
        CoverThumb(mediaId: cluster.coverId)
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .white, lineWidth: selected ? 3 : 2))
            .overlay(alignment: .topTrailing) {
                if cluster.count > 1 {
                    Text("\(cluster.count)")
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .offset(x: 8, y: -8)
                }
            }
            .shadow(radius: 2, y: 1)
            .help("\(cluster.count) photo\(cluster.count > 1 ? "s" : "")")
    }
}
