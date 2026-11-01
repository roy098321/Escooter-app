import CorckieCore
import MapKit
import SwiftUI

/// Note 18 (owner 26 Oct, option A): draw a place's outline like Google Earth. Tap the map to add a corner, drag a corner to move it,
/// tap a small handle between two corners to insert one there; Undo, Reset, the area. Save needs 3 corners. The editing rules live in
/// Core (`OutlineEditor`, tested on Linux); this view only turns touches into map coordinates.
struct PlaceOutlineEditor: View {
    let title: String
    let centre: CLLocationCoordinate2D
    let circleM: Double
    let colourId: String
    var onSave: ([GeoPoint]) -> Void

    @State private var editor: OutlineEditor
    /// a corner being dragged: its index and where it is now (the editor only learns the end of the drag: one undo step)
    @State private var dragging: (index: Int, point: GeoPoint)?
    @State private var camera: MapCameraPosition
    @Environment(\.dismiss) private var dismiss

    init(title: String, centre: CLLocationCoordinate2D, circleM: Double, colourId: String, points: [GeoPoint], onSave: @escaping ([GeoPoint]) -> Void) {
        self.title = title
        self.centre = centre
        self.circleM = circleM
        self.colourId = colourId
        self.onSave = onSave
        _editor = State(initialValue: OutlineEditor(points: points))
        _camera = State(initialValue: .region(MKCoordinateRegion(center: centre, latitudinalMeters: circleM * 5, longitudinalMeters: circleM * 5)))
    }

    private var shownPoints: [GeoPoint] {
        var p = editor.points
        if let d = dragging, p.indices.contains(d.index) { p[d.index] = d.point }
        return p
    }

    private static func coord(_ p: GeoPoint) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }

    var body: some View {
        let colour = PlaceColourStore.color(colourId)
        let points = shownPoints
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if !editor.isValid {
                    // the circle it replaces, faint, as a guide
                    MapCircle(center: centre, radius: circleM).foregroundStyle(colour.opacity(0.08)).stroke(colour.opacity(0.4), lineWidth: 1)
                }
                if points.count >= PlaceOutline.minPoints {
                    MapPolygon(coordinates: points.map(Self.coord)).foregroundStyle(colour.opacity(0.22)).stroke(colour, lineWidth: 2)
                } else if points.count == 2 {
                    MapPolyline(coordinates: points.map(Self.coord)).stroke(colour, lineWidth: 2)
                }
                if dragging == nil {
                    ForEach(Array(editor.midpoints.enumerated()), id: \.offset) { _, m in
                        Annotation("", coordinate: Self.coord(m.point), anchor: .center) {
                            Button { editor.insertMidpoint(after: m.after); Haptics.light() } label: {
                                Circle().fill(Color.white.opacity(0.9)).frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(colour, lineWidth: 2))
                                    .frame(width: 36, height: 36).contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add a corner here")
                        }
                    }
                }
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    Annotation("", coordinate: Self.coord(p), anchor: .center) {
                        Circle().fill(colour).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.white, lineWidth: 3))
                            .frame(width: 44, height: 44).contentShape(Circle())
                            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                                .onChanged { v in
                                    if let c = proxy.convert(v.location, from: .global) { dragging = (i, GeoPoint(lat: c.latitude, lon: c.longitude)) }
                                }
                                .onEnded { _ in
                                    if let d = dragging { editor.move(d.index, to: d.point) }
                                    dragging = nil
                                })
                            .accessibilityLabel("Corner \(i + 1)")
                    }
                }
            }
            .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
            .onTapGesture { location in
                guard dragging == nil, editor.canAdd, let c = proxy.convert(location, from: .local) else { return }
                editor.add(GeoPoint(lat: c.latitude, lon: c.longitude))
                Haptics.light()
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .screen("Place outline")
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            Button("Save") {
                onSave(editor.points)
                Haptics.success()
                dismiss()
            }
            .font(.body.weight(.semibold))
            .disabled(!editor.isValid)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DS.hit)
        .background(.thinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(editor.areaLine ?? (editor.points.isEmpty ? "Tap the map to add corners" : "Add \(PlaceOutline.minPoints - editor.points.count) more"))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            HStack(spacing: 12) {
                Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!editor.canUndo)
                Spacer()
                Button(role: .destructive) { editor.reset() } label: { Label("Reset", systemImage: "trash") }
                    .disabled(editor.points.isEmpty)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.thinMaterial)
    }
}
