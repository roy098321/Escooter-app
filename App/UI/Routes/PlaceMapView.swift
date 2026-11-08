import CorckieCore
import MapKit
import SwiftUI

/// F-06 / F-08: a coloured pin with its circle, as every map in the app draws a place.
struct PlaceMarks: MapContent {
    let coordinate: CLLocationCoordinate2D
    let radiusM: Double
    let colourId: String
    var name: String = ""
    /// Note 18: drawn instead of the circle when the place has an outline
    var outline: [CLLocationCoordinate2D]? = nil

    var body: some MapContent {
        let c = PlaceColourStore.color(colourId)
        if let outline, outline.count >= PlaceOutline.minPoints {
            MapPolygon(coordinates: outline)
                .foregroundStyle(c.opacity(0.22))
                .stroke(c, lineWidth: 2)
        } else {
            MapCircle(center: coordinate, radius: radiusM)
                .foregroundStyle(c.opacity(0.22))
                .stroke(c, lineWidth: 2)
        }
        Marker(name, systemImage: "mappin", coordinate: coordinate).tint(c)
    }
}

/// F-08: the row of colours to pick from
struct PlaceColourPicker: View {
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlaceColours.all, id: \.id) { choice in
                Button { onPick(choice.id) } label: {
                    Circle()
                        .fill(Color(hex: choice.hex))
                        .frame(width: 30, height: 30)
                        .overlay {
                            if choice.id == selected {
                                Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 40, height: DS.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.name)
                .accessibilityAddTraits(choice.id == selected ? [.isSelected] : [])
            }
        }
    }
}

/// F-06: one place on a full map: pin, circle, name, the street below it, and Rename, circle size, colour and "I can charge here".
struct PlaceMapView: View {
    var placeId: String?
    var preview: PlaceMapItem?

    @State private var item: PlaceMapItem?
    @State private var street: String?
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var errorText: String?
    /// F-39 flaw 6: a wider circle to offer, nil = none
    @State private var widenTo: Double?
    /// Note 18: the outline editor is open / "Use the circle again?" is asked
    @State private var editingOutline = false
    @State private var askCircle = false
    @Environment(\.dismiss) private var dismiss

    private var shown: PlaceMapItem? { preview ?? item }

    var body: some View {
        Group {
            if let place = shown {
                content(place)
            } else {
                ContentUnavailableView("Place not found", systemImage: "mappin.slash")
            }
        }
        .background { Theme.background.ignoresSafeArea() }
        .navigationTitle(shown?.row.title ?? "Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(shown == nil ? .automatic : .hidden, for: .navigationBar)   // the bar over the map replaces it
        .alert("Rename place", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { let draft = nameDraft; save { try PlaceService.rename(placeId: $0.id, name: draft, database: $1) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to remove the name.")
        }
        .alert("Could not change the place", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: reload)
        .task(id: placeId) { await lookUpStreet() }
        .fullScreenCover(isPresented: $editingOutline) {
            if let place = shown {
                PlaceOutlineEditor(title: place.row.title, centre: place.coordinate, circleM: place.circleM, colourId: place.colourId,
                                   points: place.outline ?? []) { points in
                    save { try PlaceOutlineStore.save($1, placeId: $0.id, outline: points) }
                }
            }
        }
        .confirmationDialog("Use the circle again?", isPresented: $askCircle, titleVisibility: .visible) {
            Button("Use the circle", role: .destructive) { save { try PlaceOutlineStore.save($1, placeId: $0.id, outline: nil) } }
            Button("Keep the outline", role: .cancel) {}
        } message: {
            Text("The outline you drew is removed.")
        }
        .hidesTabBar()                // B28: the place screen has actions; nothing may sit under the bar
        .screen("Place")
    }

    /// B29: a map of fixed height with the place's cards in a normal scroll view below it
    private func content(_ place: PlaceMapItem) -> some View {
        MapScreen {
            Map(initialPosition: .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: place.circleM * 8, longitudinalMeters: place.circleM * 8)),
                interactionModes: [.pan, .zoom]) {
                PlaceMarks(coordinate: place.coordinate, radiusM: place.circleM, colourId: place.colourId, name: place.row.hasName ? place.row.title : "",
                           outline: place.outlineCoords)
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .accessibilityLabel("Map of \(place.row.title)")
        } topBar: {
            GlassTopBar(title: place.row.title, subtitle: street) {
                GlassIconButton(symbol: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                EmptyView()
            }
        } content: {
            VStack(spacing: 12) {
                titleCard(place)
                settingsCard(place)
                if place.row.hasName { PlaceHomeCard(placeId: place.id, name: place.row.title, colourId: place.colourId, preview: preview != nil) }   // F-29
            }
        }
    }

    private func titleCard(_ place: PlaceMapItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.row.title).font(.title3.weight(.semibold)).foregroundStyle(place.row.hasName ? Color.primary : Color.secondary)
                Text(street ?? "Looking for the street name").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") {
                nameDraft = place.row.hasName ? place.row.title : ""
                renaming = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
    }

    private func settingsCard(_ place: PlaceMapItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let w = widenTo, place.outline == nil {
                // F-39 flaw 6: one tap, never silent
                Button(TripRules.widenText(placeName: place.row.title)) {
                    save { try PlaceService.setRadius(placeId: $0.id, radiusM: w, database: $1) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentInk)
            }
            Toggle(isOn: Binding(get: { place.row.canCharge },
                                 set: { on in save { try PlaceService.setCanCharge(placeId: $0.id, canCharge: on, database: $1) } })) {
                Label {
                    Text("I can charge here")
                } icon: {
                    Image(systemName: "powerplug").foregroundStyle(Theme.canyon)
                }
            }
            // note 18: Circle (default) | Outline you draw
            Picker("Shape", selection: Binding(get: { place.outline != nil },
                                               set: { outline in
                                                   if outline { editingOutline = true } else if place.outline != nil { askCircle = true }
                                               })) {
                Text("Circle").tag(false)
                Text("Outline").tag(true)
            }
            .pickerStyle(.segmented)
            if let poly = place.outline {
                HStack {
                    Text(PlaceListBuilder.outlineText(PlaceOutline.areaM2(poly))).monospacedDigit()
                    Spacer()
                    Button("Edit outline") { editingOutline = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Text("Circle")
                    Spacer()
                    Picker("Circle", selection: Binding(get: { place.row.radiusM ?? 0 },
                                                        set: { r in save { try PlaceService.setRadius(placeId: $0.id, radiusM: r > 0 ? r : nil, database: $1) } })) {
                        Text("Automatic").tag(0.0)
                        ForEach(PlaceListBuilder.radiusChoices, id: \.self) { r in
                            Text("\(Int(r)) m").tag(r)
                        }
                    }
                    .labelsHidden()
                }
            }
            Text("Colour").font(.subheadline).foregroundStyle(.secondary)
            PlaceColourPicker(selected: place.colourId) { id in
                save { try PlaceColourStore.write(placeId: $0.id, colourId: id, database: $1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
    }

    private func reload() {
        guard preview == nil, let id = placeId, let db = AppModel.shared.displayDatabase else { return }
        item = PlaceMapLoader.item(placeId: id, database: db)
        widenTo = ScreenSimulator.shared.active ? nil : PlaceWiden.suggestion(placeId: id, database: db)
    }

    private func save(_ action: (PlaceMapItem, AppDatabase) throws -> Void) {
        guard preview == nil, let place = item, let db = AppModel.shared.displayDatabase else { return }
        do {
            try action(place, db)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// P-2: only the rounded coordinates leave the phone, through the one helper that caches every answer (`RouteNaming`)
    private func lookUpStreet() async {
        if preview != nil { street = "Example Street"; return }
        guard let id = placeId, let db = AppModel.shared.displayDatabase, let p = try? RouteQueries(db).place(id: id) else { return }
        let r = await RouteNaming.shared.street(at: GeoPoint(lat: p.lat, lon: p.lon), database: db)
        if let s = r.street { street = s } else { street = r.answered ? "No street name here" : "Street name needs a connection" }
    }
}

/// F-06: the start and end place of a ride or route on its map: a pin in the place colour with the place name.
struct PlacePinMarks: MapContent {
    let pins: [PlacePin]

    var body: some MapContent {
        ForEach(pins) { p in
            Marker(p.name, systemImage: "mappin", coordinate: p.coordinate).tint(PlaceColourStore.color(p.colourId))
        }
    }
}

extension PlaceColourStore {
    static func color(_ id: String?) -> Color { Color(hex: PlaceColours.hex(id)) }
}
