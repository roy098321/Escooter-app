import CorckieCore
import MapKit
import SwiftUI

/// N4-1 (batch 4, owner 9 Nov): move a place's circle centre. Drag the pin or tap the map; the circle follows; Undo; Save keeps it
/// (a detected place is never re-detected, so the saved centre wins). The rules live in Core (`CentreEditor`, tested on Linux).
struct PlaceCentreEditor: View {
    let title: String
    let circleM: Double
    let colourId: String
    var onSave: (GeoPoint) -> Void

    @State private var editor: CentreEditor
    /// the pin while it is dragged (the editor learns only the end: one undo step)
    @State private var dragging: GeoPoint?
    @State private var camera: MapCameraPosition
    @Environment(\.dismiss) private var dismiss

    init(title: String, centre: GeoPoint, circleM: Double, colourId: String, onSave: @escaping (GeoPoint) -> Void) {
        self.title = title
        self.circleM = circleM
        self.colourId = colourId
        self.onSave = onSave
        _editor = State(initialValue: CentreEditor(centre: centre))
        _camera = State(initialValue: .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: centre.lat, longitude: centre.lon),
                                                                 latitudinalMeters: circleM * 5, longitudinalMeters: circleM * 5)))
    }

    private static func coord(_ p: GeoPoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }

    var body: some View {
        let colour = PlaceColourStore.color(colourId)
        let centre = dragging ?? editor.centre
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                MapCircle(center: Self.coord(centre), radius: circleM).foregroundStyle(colour.opacity(0.22)).stroke(colour, lineWidth: 2)
                Annotation("", coordinate: Self.coord(centre), anchor: .center) {
                    Circle().fill(colour).frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.white, lineWidth: 3))
                        .frame(width: 48, height: 48).contentShape(Circle())
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { v in
                                if let c = proxy.convert(v.location, from: .global) { dragging = GeoPoint(lat: c.latitude, lon: c.longitude) }
                            }
                            .onEnded { _ in
                                if let d = dragging { editor.move(to: d) }
                                dragging = nil
                            })
                        .accessibilityLabel("Centre of the circle")
                }
            }
            .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
            .onTapGesture { location in
                guard dragging == nil, let c = proxy.convert(location, from: .local) else { return }
                editor.move(to: GeoPoint(lat: c.latitude, lon: c.longitude))
                Haptics.light()
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .screen("Place centre")
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            Button("Save") {
                onSave(editor.centre)
                Haptics.success()
                dismiss()
            }
            .font(.body.weight(.semibold))
            .disabled(!editor.changed)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DS.hit)
        .background(.thinMaterial)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text(editor.changed ? "Moved \(Int(editor.movedM.rounded())) m" : "Drag the pin or tap the map")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.bordered)
                .disabled(!editor.canUndo)
        }
        .padding(16)
        .background(.thinMaterial)
    }
}
