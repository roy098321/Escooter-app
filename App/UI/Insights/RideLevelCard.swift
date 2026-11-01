import Charts
import CorckieCore
import SwiftUI

/// Batch 102 insights plan: one whole-ride insight. Title, "early read" tag, the range of the effect, the bar with its marks, the real
/// progress ("About 7 more rides" / "Waiting for colder days"), the partial graph (solid where rides cover it, a dashed top and bottom
/// where data is thin) and one short hint. Never "can't learn this". The speed card adds the riding ask (option b) under the hint.
struct RideLevelCard: View {
    let insight: RideLevelInsight
    /// riding asks: how many stretches the rider skipped with "Not here" while the card is open
    @State private var skipped = 0

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
    }

    /// Riding asks (option b): "800 m steady at 35 km/h fills your speed graph." and where it fits, with "Not here"
    @ViewBuilder private func askLines(_ ask: RidingAsk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ask.line).font(.subheadline.weight(.semibold))
            if skipped < insight.askStretches.count {
                let spot = insight.askStretches[skipped]
                HStack(alignment: .firstTextBaseline) {
                    Text(spot.line).font(.footnote).foregroundStyle(.secondary)
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
        }
        .padding(12)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
