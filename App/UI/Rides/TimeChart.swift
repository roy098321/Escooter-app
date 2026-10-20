import Charts
import CorckieCore
import SwiftUI

/// F-18 / F-28: one value against ride time with a cursor line. A finger on the chart moves the cursor (Core `ChartCursor` turns the
/// finger into a time); the Replay strip and the full-screen speed / battery charts share this view, so every chart reads the same instant.
struct TimeChart: View {
    struct Point: Identifiable {
        let id: Int
        let t: Double
        let v: Double
    }

    let points: [Point]
    let domain: ClosedRange<Double>
    var cursor: Double?
    var colour: Color = Theme.accent
    var unit: String
    var step = false
    /// nil = from the points with a little room
    var yDomain: ClosedRange<Double>?
    var yTicks: [Double]?
    /// nil = as tall as there is room
    var height: CGFloat?
    var onScrub: ((Double) -> Void)?

    var body: some View {
        let y = yDomain ?? Self.range(points)
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value(unit, p.v))
                    .foregroundStyle(colour)
                    .interpolationMethod(step ? .stepEnd : .linear)
            }
            if let cursor {
                RuleMark(x: .value("Time", cursor))
                    .foregroundStyle(Theme.accentInk)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: y)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let s = value.as(Double.self) { Text(ChartCursor.clock(s)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: yTicks ?? Self.ticks(y))
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let onScrub {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            guard let anchor = proxy.plotFrame else { return }
                            let frame = geo[anchor]
                            onScrub(ChartCursor.time(atX: Double(g.location.x - frame.minX), width: Double(frame.width), domain: domain))
                        })
                }
            }
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .accessibilityLabel("\(unit) against time")
    }

    static func range(_ points: [Point]) -> ClosedRange<Double> {
        guard let lo = points.map(\.v).min(), let hi = points.map(\.v).max() else { return 0...1 }
        let pad = Swift.max(1, (hi - lo) * 0.1)
        return (lo >= 0 ? Swift.max(0, lo - pad) : lo - pad)...(hi + pad)
    }

    /// Three labels only (bottom, middle, top), so a short chart never crowds them (B37)
    static func ticks(_ y: ClosedRange<Double>) -> [Double] {
        let mid = (y.lowerBound + y.upperBound) / 2
        return [y.lowerBound, mid, y.upperBound].map { $0.rounded() }
    }

    /// The readings of one value inside a shown window (thinned for drawing)
    static func points(times: [Double], values: [Double], domain: ClosedRange<Double>, max: Int = 600) -> [Point] {
        ChartCursor.visible(times, domain: domain, max: max).map { Point(id: $0, t: times[$0], v: values[$0]) }
    }
}
