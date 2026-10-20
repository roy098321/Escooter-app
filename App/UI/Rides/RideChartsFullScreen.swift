import CorckieCore
import SwiftUI
import UIKit

/// F-28 (P6-4): the ride's speed and battery charts full screen (tap a chart on the ride detail). Landscape is allowed here only.
/// Both charts share one time axis and one cursor: pinch to zoom on time, a finger on either chart reads the exact values of the
/// nearest reading. The cursor and the zoom are Core `ChartCursor`, the same as the Replay strip's.
struct RideChartsFullScreen: View {
    let points: [SeriesPoint]

    @Environment(\.dismiss) private var dismiss
    @State private var full: ClosedRange<Double> = 0...1
    @State private var domain: ClosedRange<Double> = 0...1
    @State private var pinchBase: ClosedRange<Double>?
    @State private var cursor: Double?
    @State private var speedTimes: [Double] = []
    @State private var speeds: [Double] = []
    @State private var batteryTimes: [Double] = []
    @State private var batteries: [Double] = []
    @State private var ready = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text("Speed").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.sectionLabel)
            TimeChart(points: TimeChart.points(times: speedTimes, values: speeds, domain: domain), domain: domain, cursor: cursor,
                      colour: Theme.accent, unit: "km/h") { cursor = $0 }
            Text("Battery").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.sectionLabel)
            let axis = ChartCursor.batteryAxis(min: batteries.min() ?? 0, max: batteries.max() ?? 100)
            TimeChart(points: TimeChart.points(times: batteryTimes, values: batteries, domain: domain), domain: domain, cursor: cursor,
                      colour: Theme.ok, unit: "%", step: true, yDomain: axis.domain, yTicks: axis.ticks) { cursor = $0 }
            if zoomed {
                Slider(value: Binding(get: { domain.lowerBound },
                                      set: { domain = ChartCursor.panned(domain, full: full, byS: $0 - domain.lowerBound) }),
                       in: full.lowerBound...max(full.lowerBound + 0.001, full.upperBound - (domain.upperBound - domain.lowerBound)))
                    .accessibilityLabel("Move the shown time")
            }
            Text("Pinch to zoom on time \u{00B7} touch a chart to read it").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.vertical, 8)
        .background(Theme.background.ignoresSafeArea())
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in
                    let base = pinchBase ?? domain
                    pinchBase = base
                    domain = ChartCursor.zoomed(base, full: full, scale: Double(v.magnification), anchor: Double(v.startAnchor.x))
                }
                .onEnded { _ in pinchBase = nil }
        )
        .onAppear {
            setUp()
            OrientationLock.allow(landscape: true)
        }
        .onDisappear { OrientationLock.allow(landscape: false) }
        .screen("Ride charts")
    }

    private var zoomed: Bool { domain.upperBound - domain.lowerBound < full.upperBound - full.lowerBound - 0.5 }

    private var header: some View {
        HStack(spacing: 12) {
            GlassIconButton(symbol: "xmark", label: "Close") { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text(cursor.map { ChartCursor.clock($0) } ?? "Speed and battery").font(.headline).monospacedDigit()
                Text(readout).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if zoomed {
                Button("Reset") { domain = full }
                    .fontWeight(.semibold)
            }
        }
    }

    /// The exact values at the cursor: the nearest speed reading, the battery reading in force then
    private var readout: String {
        guard let cursor else { return "Touch a chart" }
        var parts: [String] = []
        if let i = ChartCursor.nearestIndex(speedTimes, to: cursor) { parts.append(String(format: "%.1f km/h", speeds[i])) }
        if let i = ChartCursor.lastIndex(batteryTimes, atOrBefore: cursor) ?? (batteryTimes.isEmpty ? nil : 0) {
            parts.append("\(Int(batteries[i]))% battery")
        }
        return parts.isEmpty ? "No reading here" : parts.joined(separator: " \u{00B7} ")
    }

    private func setUp() {
        guard !ready else { return }
        ready = true
        let sorted = points.sorted { $0.t < $1.t }
        let t0 = sorted.first?.t ?? 0
        for p in sorted {
            if let v = p.speedKmh { speedTimes.append(p.t - t0); speeds.append(v) }
            if let b = p.batteryPct { batteryTimes.append(p.t - t0); batteries.append(Double(b)) }
        }
        full = 0...max(1, (sorted.last?.t ?? 1) - t0)
        domain = full
    }
}

/// F-28: the app is portrait; the full-screen charts open it to landscape while they are shown (AppDelegate asks this).
enum OrientationLock {
    @MainActor static var mask: UIInterfaceOrientationMask = .portrait

    @MainActor static func allow(landscape: Bool) {
        mask = landscape ? .allButUpsideDown : .portrait
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            var vc = window.rootViewController
            while let c = vc {
                c.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = c.presentedViewController
            }
        }
        if !landscape { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
    }
}
