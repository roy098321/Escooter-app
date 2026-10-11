import Charts
import CorckieCore
import SwiftUI

/// M5-03: the elevation panel (profile + the real cost of each climb) and the speed / battery charts of the full ride detail.
struct RideSeriesPanels: View {
    let series: RideSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            elevationPanel
            if series.chart.count >= 2 { chartsPanel }
        }
    }

    // MARK: Elevation

    private var elevationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Elevation").font(.headline)
            if series.profile.count >= 2 {
                Chart {
                    ForEach(Array(series.profile.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Distance", p.distM / 1000), y: .value("Altitude", p.altM))
                            .foregroundStyle(Color.accentColor.opacity(0.25))
                        LineMark(x: .value("Distance", p.distM / 1000), y: .value("Altitude", p.altM))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxisLabel("km")
                .chartYAxisLabel("m")
                .frame(height: 130)
                .accessibilityLabel("Elevation chart, metres against kilometres")
                if series.climbs.isEmpty {
                    Text("No climbs of 5 m or more.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(series.climbs.enumerated()), id: \.offset) { i, c in
                        HStack {
                            Text("Climb \(i + 1)").font(.subheadline)
                            Spacer()
                            Text(c.text).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if i < series.climbs.count - 1 { Divider() }
                    }
                }
            } else {
                Text("No altitude readings on this ride.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Speed and battery

    private var chartsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed and battery").font(.headline)
            Chart {
                ForEach(Array(series.chart.enumerated()), id: \.offset) { _, p in
                    if let v = p.speedKmh {
                        LineMark(x: .value("Minutes", p.t / 60), y: .value("km/h", v))
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxisLabel("min")
            .chartYAxisLabel("km/h")
            .frame(height: 110)
            .accessibilityLabel("Speed chart, kilometres per hour against minutes")
            Chart {
                ForEach(Array(series.chart.enumerated()), id: \.offset) { _, p in
                    if let b = p.batteryPct {
                        LineMark(x: .value("Minutes", p.t / 60), y: .value("Battery", b))
                            .foregroundStyle(Color.green)
                            .interpolationMethod(.stepEnd)
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxisLabel("min")
            .chartYAxisLabel("%")
            .frame(height: 90)
            .accessibilityLabel("Battery chart, percent against minutes")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension MapLayer {
    /// Level 0...4 of the Hills and Wind layers: blue = down / with you, grey = flat / across, red = up / against
    static func color(level: Int) -> Color {
        let colors: [Color] = [Color(red: 0.20, green: 0.45, blue: 0.95), Color(red: 0.45, green: 0.75, blue: 0.95), .gray,
                               .orange, .red]
        return colors[min(max(level, 0), colors.count - 1)]
    }
}
