import CorckieCore
import MapKit
import SwiftUI

/// F-13: Apple's address completion for the search field. The typed text goes to Apple's search, nothing else.
final class AddressSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    struct Hit: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let completion: MKLocalSearchCompletion?
    }

    @Published var hits: [Hit] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { hits = [] }
        completer.queryFragment = t
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let list = completer.results.prefix(5).map { Hit(title: $0.title, subtitle: $0.subtitle, completion: $0) }
        DispatchQueue.main.async { self.hits = list }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async { self.hits = [] }
    }

    /// the coordinate of a picked completion
    static func resolve(_ hit: Hit) async -> CLLocationCoordinate2D? {
        guard let completion = hit.completion else { return nil }
        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response?.mapItems.first?.placemark.coordinate
    }
}

/// F-13: add a place by hand: long-press the map (or use the centre button, or search an address), then name, circle size and colour.
/// It is saved in the same table as the places the app learns, so rides are matched to it the same way.
struct PlaceAddView: View {
    /// ui-shots: a made-up dropped pin
    var preview: Bool = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = AddressSearch()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var centre: CLLocationCoordinate2D?
    @State private var pin: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var name = ""
    @State private var radius = 0.0
    @State private var chosenColour: String?
    @State private var existing: [String: String] = [:]
    @State private var errorText: String?

    private var colour: String {
        chosenColour ?? PlaceColours.assign(places: [(id: "new", name: name)], existing: existing)["new"] ?? "orange"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                mapLayer
                searchBox
            }
            formCard
        }
        .background { MapBackdrop().ignoresSafeArea() }
        .navigationTitle("Add a place")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Could not save the place", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: start)
        .screen("Add place")
    }

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if let p = pin {
                    PlaceMarks(coordinate: p, radiusM: radius > 0 ? radius : PlaceMapItem.automaticCircleM, colourId: colour)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { context in centre = context.region.center }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        if case .second(true, let drag?) = value, let c = proxy.convert(drag.location, from: .local) {
                            Haptics.warning()
                            pin = c
                        }
                    }
            )
        }
        .accessibilityLabel("Map. Press and hold to drop a pin.")
    }

    private var searchBox: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search an address", text: $query)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onChange(of: query) { _, text in search.update(text) }
                if !query.isEmpty {
                    Button { query = ""; search.update("") } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: DS.hit)
            .sunPanel(Capsule(), thin: true)
            if !search.hits.isEmpty && !query.isEmpty {
                hitList
            }
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.top, 8)
    }

    private var hitList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(search.hits) { hit in
                Button { pick(hit) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if !hit.subtitle.isEmpty { Text(hit.subtitle).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(minHeight: DS.hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard(padding: 0)
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pin == nil {
                Text("Press and hold on the map to drop a pin, search an address, or").font(.footnote).foregroundStyle(.secondary)
                Button { pin = centre } label: { Label("Drop a pin at the middle of the map", systemImage: "mappin.and.ellipse") }
                    .buttonStyle(.bordered)
                    .disabled(centre == nil)
            } else {
                TextField("Name (for example Gym)", text: $name)
                    .textFieldStyle(.roundedBorder)
                Picker("Circle", selection: $radius) {
                    Text("Automatic").tag(0.0)
                    ForEach(PlaceListBuilder.radiusChoices, id: \.self) { r in Text("\(Int(r)) m").tag(r) }
                }
                PlaceColourPicker(selected: colour) { chosenColour = $0 }
                HStack {
                    Button("Move the pin") { pin = nil }.buttonStyle(.bordered)
                    Spacer()
                    Button("Save place") { save() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
        .padding(.horizontal, DS.Space.gutter)
        .padding(.vertical, 8)
    }

    private func start() {
        if preview {
            let c = CLLocationCoordinate2D(latitude: 40.0105, longitude: -74.9885)
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
            pin = c
            name = "Gym"
            existing = ["p1": "green", "p2": "blue"]
            return
        }
        if let db = AppModel.shared.displayDatabase { existing = PlaceColourStore.colours(database: db) }
    }

    private func pick(_ hit: AddressSearch.Hit) {
        query = ""
        search.update("")
        Task {
            guard let c = await AddressSearch.resolve(hit) else { return }
            pin = c
            if name.isEmpty { name = hit.title }
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800))
        }
    }

    private func save() {
        guard !preview else { return }
        guard let p = pin else { return }
        guard let db = AppModel.shared.database, !db.isReadOnly else {
            errorText = "The data is read-only in this build."
            return
        }
        do {
            try PlaceAddService.add(name: name, lat: p.latitude, lon: p.longitude, radiusM: radius > 0 ? radius : nil, colourId: colour, database: db)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
