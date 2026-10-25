import CorckieCore
import MapKit
import SwiftUI

/// F-04: continuous gradient paths on the ride maps. The ramps and fixed scales come from Core (`LayerRamps`); the line is one short
/// coloured stretch after another with round caps, so the shade follows the value without steps.
enum GradientPath {
    static func color(_ ramp: GradientRamp, _ value: Double) -> Color {
        let c = ramp.rgb(at: value)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func color(_ layer: MapLayer, _ value: Double) -> Color {
        color(LayerRamps.ramp(layer, colourBlind: DisplaySettings.colourBlind), value)
    }

    /// The stretches of a layer as map lines (MapKit equivalent of a gradient polyline)
    @MainActor @MapContentBuilder
    static func lines(_ stretches: [ValueStretch], layer: MapLayer, width: CGFloat = 5) -> some MapContent {
        lines(stretches, ramp: LayerRamps.ramp(layer, colourBlind: DisplaySettings.colourBlind), width: width)
    }

    /// F-33: any view's stretches on its own ramp
    @MainActor @MapContentBuilder
    static func lines(_ stretches: [ValueStretch], ramp: GradientRamp, width: CGFloat = 5) -> some MapContent {
        ForEach(Array(stretches.enumerated()), id: \.offset) { _, s in
            MapPolyline(coordinates: [CLLocationCoordinate2D(latitude: s.a.lat, longitude: s.a.lon),
                                      CLLocationCoordinate2D(latitude: s.b.lat, longitude: s.b.lon)])
                .stroke(color(ramp, s.value), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A small gradient bar with its end values, for the map layers.
struct GradientLegend: View {
    let layer: MapLayer
    @Environment(\.sunlight) private var sunlight

    var body: some View {
        let ramp = LayerRamps.ramp(layer, colourBlind: DisplaySettings.colourBlind)
        let text = LayerRamps.legend(layer)
        let steps = 12
        let colours = (0...steps).map { i in
            GradientPath.color(ramp, ramp.lo + (ramp.hi - ramp.lo) * Double(i) / Double(steps))
        }
        VStack(spacing: 3) {
            LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing)
                .frame(height: 8)
                .clipShape(Capsule())
            HStack {
                Text(text.low)
                Spacer(minLength: 4)
                Text(text.high)
            }
            .font(.caption2.weight(sunlight ? .bold : .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(width: 150)
        .padding(8)
        .glassCard(radius: 12, padding: 0, thin: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour scale, \(text.low) to \(text.high)")
    }
}

/// The live path as gradient stretches. The live path only knows 5 speed classes per run, so each run counts as the middle of its class
/// (5 / 15 / 25 / 35 / 45 km/h) and the values are blended over ~10 s of riding; stretches are at least 30 m long to keep the map light.
/// Cached by the number of points, so a redraw without a new point costs nothing.
enum LiveGradient {
    struct Stretch {
        var coords: [LivePath.Coord]
        var value: Double
        var dashed: Bool
    }

    private static var cacheKey = ""
    private static var cache: [Stretch] = []
    private static let centres: [Double] = [5, 15, 25, 35, 45]
    private static let minStretchM = 30.0

    static func stretches(_ path: LivePath) -> [Stretch] {
        let last = path.segments.last?.coords.last
        let key = "\(path.pointCount)|\(last?.lat ?? 0)|\(last?.lon ?? 0)"
        if key == cacheKey { return cache }
        cache = build(path)
        cacheKey = key
        return cache
    }

    private struct Edge {
        var a: LivePath.Coord
        var b: LivePath.Coord
        var value: Double
        var dashed: Bool
        var lengthM: Double
        var midM = 0.0
    }

    private static func build(_ path: LivePath) -> [Stretch] {
        var edges: [Edge] = []
        var run = 0.0
        for seg in path.segments where seg.coords.count >= 2 {
            let v = centres[min(max(seg.bucket, 0), centres.count - 1)]
            for k in 1..<seg.coords.count {
                let a = seg.coords[k - 1], b = seg.coords[k]
                var e = Edge(a: a, b: b, value: v, dashed: seg.dashed, lengthM: metres(a, b))
                e.midM = run + e.lengthM / 2
                run += e.lengthM
                edges.append(e)
            }
        }
        guard !edges.isEmpty else { return [] }
        // blend over ~10 s: half a window of 5 s at the edge's own speed (at least 15 m)
        var smooth = edges.map(\.value)
        var lo = 0
        var hi = 0
        for i in edges.indices {
            let half = max(15, edges[i].value / 3.6 * 5)
            while lo < i, edges[lo].midM < edges[i].midM - half { lo += 1 }
            if hi < i { hi = i }
            while hi + 1 < edges.count, edges[hi + 1].midM <= edges[i].midM + half { hi += 1 }
            var sum = 0.0
            for j in lo...hi { sum += edges[j].value }
            smooth[i] = sum / Double(hi - lo + 1)
        }
        // group into stretches of at least `minStretchM` (a change of line style starts a new one)
        var out: [Stretch] = []
        var coords: [LivePath.Coord] = []
        var length = 0.0
        var weighted = 0.0
        var dashed = edges[0].dashed
        func flush() {
            if coords.count >= 2, length > 0 { out.append(Stretch(coords: coords, value: weighted / length, dashed: dashed)) }
            coords = []
            length = 0
            weighted = 0
        }
        for (i, e) in edges.enumerated() {
            if e.dashed != dashed { flush(); dashed = e.dashed }
            if coords.isEmpty { coords = [e.a] }
            coords.append(e.b)
            length += e.lengthM
            weighted += smooth[i] * e.lengthM
            if length >= minStretchM { flush() }
        }
        flush()
        return out
    }
}

extension LiveGradient {
    fileprivate static func metres(_ a: LivePath.Coord, _ b: LivePath.Coord) -> Double {
        let dLat = (b.lat - a.lat) * 111_320
        let dLon = (b.lon - a.lon) * 111_320 * cos(a.lat * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}
