import Charts
import CorckieCore
import MapKit
import SwiftUI

/// Batch 102 insights plan: one whole-ride insight. Title, "early read" tag, the range of the effect, the bar with its marks, the real
/// progress ("About 7 more rides" / "Waiting for colder days"), the partial graph (solid where rides cover it, a dashed top and bottom
/// where data is thin) and one short hint. Never "can't learn this". The speed card adds the riding ask (option b) under the hint.
struct RideLevelCard: View {
    let insight: RideLevelInsight
    /// riding asks: how many stretches the rider skipped with "Not here" while the card is open
    @State private var skipped = 0
    /// N4-2: the street names of the stretch shown (key → main, from, to); "Show where" opens its small map
    @State private var streets: [String: (main: String?, from: String?, to: String?)] = [:]
    @State private var showWhere: AskStretch?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(insight.title).font(.headline)
                Spacer(minLength: 8)
                if insight.stage == .early {
                    Text("early read").font(.caption.weight(.semibold)).foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }
            }
            if let range = insight.range {
                VStack(alignment: .leading, spacing: 2) {
                    Text(range).scaledFont(24, weight: .semibold, relativeTo: .title2).lineLimit(1).minimumScaleFactor(0.6)
                    if let ctx = insight.rangeContext { Text(ctx).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if !insight.curve.isEmpty { PartialCurveChart(curve: insight.curve, unit: insight.topic.unit) }
            if insight.stage != .confident {
                ProgressMarks(fraction: insight.fraction, earlyMark: insight.earlyMark)
            }
            Text(insight.progressLine).font(.footnote).foregroundStyle(.secondary)
            if let hint = insight.hint { Text(hint).font(.footnote.weight(.semibold)) }
            if insight.askDone { Label(RidingAsks.gotIt, systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ok) }
            if let ask = insight.ask { askLines(ask) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: DS.Radius.hero, padding: 0)
        .accessibilityElement(children: .contain)
        .sheet(item: Binding(get: { showWhere.map(AskStretchItem.init) }, set: { if $0 == nil { showWhere = nil } })) { item in
            AskStretchMap(stretch: item.stretch)
                .presentationDetents([.medium])
        }
    }

    /// Riding asks (option b): "800 m steady at 35 km/h fills your speed graph." and where it fits, with "Not here"
    @ViewBuilder private func askLines(_ ask: RidingAsk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ask.line).font(.subheadline.weight(.semibold))
            if skipped < insight.askStretches.count {
                let spot = insight.askStretches[skipped]
                let names = streets[spot.key]
                Text(spot.line(street: names?.main, fromStreet: names?.from, toStreet: names?.to))   // N4-2 A
                    .font(.footnote).foregroundStyle(.secondary)
                    .task(id: spot.key) { await lookUpStreets(spot) }
                HStack {
                    if !spot.path.isEmpty {
                        Button("Show where") { showWhere = spot }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 8)
                    Button("Not here") {
                        RidingAskState.addNotHere(spot.key)
                        skipped += 1
                        Haptics.tick()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Text(ask.anyLine).font(.footnote).foregroundStyle(.secondary)   // N4-2: any stretch counts
        }
        .padding(12)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// N4-2 A: the street of the stretch and of its two ends, through the one cached helper (rounded points only, P-2); offline = none
    private func lookUpStreets(_ spot: AskStretch) async {
        guard streets[spot.key] == nil, let db = AppModel.shared.displayDatabase, let mid = spot.middle else { return }
        let main = await RouteNaming.shared.street(at: mid, database: db).street
        guard main != nil else { return }
        let from = await spot.start.asyncMap { await RouteNaming.shared.street(at: $0, database: db).street } ?? nil
        let to = await spot.end.asyncMap { await RouteNaming.shared.street(at: $0, database: db).street } ?? nil
        streets[spot.key] = (main, from, to)
    }
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        guard let w = self else { return nil }
        return await f(w)
    }
}

/// N4-2 A: "Show where": a small map with the stretch in orange
private struct AskStretchItem: Identifiable {
    let stretch: AskStretch
    var id: String { stretch.key }
}

struct AskStretchMap: View {
    let stretch: AskStretch

    var body: some View {
        let coords = stretch.path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        Map(initialPosition: Self.region(stretch.path), interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: coords).stroke(Color.orange, lineWidth: 6)
            if let a = coords.first { Annotation("Start", coordinate: a, anchor: .center) { Circle().fill(Color.orange).frame(width: 12, height: 12) } }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityLabel("Map of the stretch")
        .screen("Riding ask stretch")
    }

    static func region(_ path: [GeoPoint]) -> MapCameraPosition {
        guard let lat0 = path.map(\.lat).min(), let lat1 = path.map(\.lat).max(),
              let lon0 = path.map(\.lon).min(), let lon1 = path.map(\.lon).max() else { return .automatic }
        let span = MKCoordinateSpan(latitudeDelta: max(0.004, (lat1 - lat0) * 2.2), longitudeDelta: max(0.004, (lon1 - lon0) * 2.2))
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (lat0 + lat1) / 2, longitude: (lon0 + lon1) / 2), span: span))
    }
}

/// Solid where rides cover it; a dashed top and bottom (the ~95 % band of the line) where they do not
struct PartialCurveChart: View {
    let curve: [CurvePiece]
    let unit: String

    private struct Seg: Identifiable {
        let id: Int
        let covered: Bool
        let points: [CurvePiece]
    }

    /// Runs of covered / thin steps; neighbours share their edge point so the line has no holes
    private var segments: [Seg] {
        var out: [Seg] = []
        var current: [CurvePiece] = []
        var state: Bool?
        for p in curve {
            if let s = state, s != p.covered {
                out.append(Seg(id: out.count, covered: s, points: current + [p]))
                current = []
            }
            state = p.covered
            current.append(p)
        }
        if let s = state, !current.isEmpty { out.append(Seg(id: out.count, covered: s, points: current)) }
        return out
    }

    var body: some View {
        Chart {
            ForEach(segments) { seg in
                if seg.covered {
                    ForEach(seg.points, id: \.x) { p in
                        LineMark(x: .value(unit, p.x), y: .value("% per km", p.y), series: .value("part", "s\(seg.id)"))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                } else {
                    ForEach(seg.points, id: \.x) { p in
                        LineMark(x: .value(unit, p.x), y: .value("% per km", p.hi), series: .value("part", "hi\(seg.id)"))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                    ForEach(seg.points, id: \.x) { p in
                        LineMark(x: .value(unit, p.x), y: .value("% per km", p.lo), series: .value("part", "lo\(seg.id)"))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    }
                }
            }
        }
        .chartXAxisLabel(unit)
        .chartYAxisLabel("% per km")
        .frame(height: 130)
        .accessibilityLabel("Battery per km against \(unit): solid where your rides show it, dashed where it is a guess")
    }
}
