import CorckieCore
import MapKit
import SwiftUI

/// Hotfix 01 (owner, 25 Oct): Settings → Developer → Route line lab. The same made-up ride (not a real place) drawn three ways,
/// so the owner can pick on the phone which one really shows the colour along the route:
/// A · SwiftUI `MapPolyline` stroked with a plain `Gradient` (the app's default now), optionally thinned to ≤ 16 stops,
/// B · short solid pieces, one per stretch, butt caps (the fallback),
/// C · UIKit `MKMapView` with Apple's `MKGradientPolylineRenderer`.
struct RouteLineLab: View {
    enum Way: String, CaseIterable, Identifiable {
        case a = "A", b = "B", c = "C"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .a: return "A · SwiftUI gradient"
            case .b: return "B · short pieces"
            case .c: return "C · UIKit gradient"
            }
        }
    }

    @State private var way: Way = .a
    @State private var fewStops = false
    private let ramp = LayerRamps.speed(colourBlind: DisplaySettings.colourBlind)
    private let stretches = RouteLineLab.madeUpStretches()

    var body: some View {
        VStack(spacing: 10) {
            Picker("Way", selection: $way) {
                ForEach(Way.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            Text(way.title).font(.subheadline.weight(.semibold))
            if way == .a {
                Toggle("At most 16 colour stops", isOn: $fewStops).padding(.horizontal, 16)
            }
            map
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
            Text("Made-up ride: slow (start) → fast (middle) → slow (end). The right one shows the colour change along the line.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .navigationTitle("Route line lab")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Route line lab")
    }

    @ViewBuilder private var map: some View {
        let runs = GradientLine.runs(stretches, ramp: ramp)
        switch way {
        case .a:
            Map(initialPosition: .automatic) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: run.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(GradientPath.gradient(fewStops ? RouteLineLab.thinned(run, to: 16) : run),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
            .id(fewStops)
        case .b:
            Map(initialPosition: .automatic) {
                ForEach(Array(stretches.enumerated()), id: \.offset) { _, s in
                    MapPolyline(coordinates: [CLLocationCoordinate2D(latitude: s.a.lat, longitude: s.a.lon),
                                              CLLocationCoordinate2D(latitude: s.b.lat, longitude: s.b.lon)])
                        .stroke(GradientPath.color(ramp, s.value), style: StrokeStyle(lineWidth: 6, lineCap: .butt, lineJoin: .round))
                }
            }
        case .c:
            GradientMapC(runs: runs)
        }
    }

    /// The same run with at most `count` evenly picked stops (first and last kept)
    static func thinned(_ run: GradientRun, to count: Int) -> GradientRun {
        guard run.stops.count > count, count >= 2 else { return run }
        let step = Double(run.stops.count - 1) / Double(count - 1)
        return GradientRun(coords: run.coords, stops: (0..<count).map { run.stops[Int((Double($0) * step).rounded())] })
    }

    /// A made-up S-shaped ride of ~2.4 km around a made-up spot: 8 → 32 → 8 km/h
    static func madeUpStretches() -> [ValueStretch] {
        let centre = (lat: 40.0, lon: -75.0)
        let n = 120
        var pts: [GeoPoint] = []
        for i in 0...n {
            let f = Double(i) / Double(n)
            let north = f * 1_800.0
            let east = sin(f * .pi * 3) * 350.0
            pts.append(GeoPoint(lat: centre.lat + north / 111_320, lon: centre.lon + east / (111_320 * cos(centre.lat * .pi / 180))))
        }
        return (0..<n).map { i in
            let f = Double(i) / Double(n - 1)
            return ValueStretch(a: pts[i], b: pts[i + 1], t: Double(i) * 5, value: 8 + 24 * sin(f * .pi))
        }
    }
}

/// C: Apple's own gradient line on a UIKit map
private struct GradientMapC: UIViewRepresentable {
    let runs: [GradientRun]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        var rect = MKMapRect.null
        for run in runs {
            var coords = run.coords.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let line = MKPolyline(coordinates: &coords, count: coords.count)
            context.coordinator.stops[ObjectIdentifier(line)] = run.stops
            map.addOverlay(line)
            rect = rect.union(line.boundingMapRect)
        }
        if !rect.isNull {
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
        }
        return map
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    final class Coordinator: NSObject, MKMapViewDelegate {
        var stops: [ObjectIdentifier: [GradientStop]] = [:]

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKGradientPolylineRenderer(polyline: line)
            let list = stops[ObjectIdentifier(line)] ?? []
            renderer.setColors(list.map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) },
                               locations: list.map { CGFloat($0.location) })
            renderer.lineWidth = 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
    }
}
