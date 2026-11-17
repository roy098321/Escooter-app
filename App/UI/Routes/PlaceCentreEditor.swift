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
    /// owner 18 Nov: the finger grabbed the pin; the map holds still and the pin follows the finger
    @State private var pinDrag = false
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
            Map(position: $camera, interactionModes: pinDrag ? [] : [.pan, .zoom]) {
                MapCircle(center: Self.coord(centre), radius: circleM).foregroundStyle(colour.opacity(0.22)).stroke(colour, lineWidth: 2)
                Annotation("", coordinate: Self.coord(centre), anchor: .center) {
                    Circle().fill(colour).frame(width: pinDrag ? 30 : 24, height: pinDrag ? 30 : 24)
                        .overlay(Circle().stroke(Color.white, lineWidth: 3))
                        .shadow(radius: pinDrag ? 4 : 0)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Centre of the circle")
                }
            }
            // owner 18 Nov: the same map as the place screen (not satellite)
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            // owner 18 Nov: a touch on the pin grabs it and the pin follows the finger (the map does not pan meanwhile)
            .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    if !pinDrag {
                        guard dragging == nil, let p = proxy.convert(Self.coord(editor.centre), to: .local),
                              hypot(v.startLocation.x - p.x, v.startLocation.y - p.y) <= 32 else { return }
                        pinDrag = true
                        Haptics.tick()
                    }
                    if let c = proxy.convert(v.location, from: .local) { dragging = GeoPoint(lat: c.latitude, lon: c.longitude) }
                }
                .onEnded { _ in
                    guard pinDrag else { return }
                    if let d = dragging { editor.move(to: d) }
                    dragging = nil
                    pinDrag = false
                })
            .onTapGesture { location in
                guard dragging == nil, !pinDrag, let c = proxy.convert(location, from: .local) else { return }
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
