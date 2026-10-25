import Foundation

/// Note 8 (owner 24 Oct, B): ONE chart at the top of Stats. It follows Week / Month / Year (a bar per day for a week and a month, per
/// month for a year), has the metric switch that Past weeks had (km · rides · time · ₪ saved), a clear title ("km per day"), dashed
/// reference lines behind the bars with their values, and a tap on a bar reads it ("13 Oct · 18 km"). The Past weeks card leaves Stats
/// (its history stays one tap away). Pure, tested on Linux.

public struct StatsChartBar: Equatable, Sendable {
    public var value: Double
    /// Under the bar: "M", "13", "O"
    public var axisLabel: String
    /// When tapped: "13 Oct" / "Oct"
    public var dateText: String
}

public struct StatsChartData: Equatable, Sendable {
    public var title: String
    public var bars: [StatsChartBar]
    /// The dashed lines behind the bars (round values under the tallest bar)
    public var references: [Double]
    public var metric: PastWeeksMetric

    /// "13 Oct · 18 km"
    public func readout(_ index: Int) -> String? {
        guard bars.indices.contains(index) else { return nil }
        return "\(bars[index].dateText) \u{00B7} \(StatsChart.valueText(bars[index].value, metric))"
    }

    public var maxValue: Double { bars.map(\.value).max() ?? 0 }
}

public enum StatsChart {
    /// "km per day" / "rides per month" / "minutes per day" / "₪ saved per day"
    public static func title(_ metric: PastWeeksMetric, span: StatsSpan) -> String {
        let per = span == .year ? "per month" : "per day"
        switch metric {
        case .km: return "km \(per)"
        case .rides: return "rides \(per)"
        case .time: return "minutes \(per)"
        case .saved: return "\u{20AA} saved \(per)"
        }
    }

    /// The bar's value in words: "18 km", "2 rides", "35 min", "₪12"
    public static func valueText(_ v: Double, _ metric: PastWeeksMetric) -> String {
        switch metric {
        case .km: return v > 0 && v < 10 ? String(format: "%.1f km", v) : String(format: "%.0f km", v)
        case .rides:
            let n = Int(v.rounded())
            return "\(n) ride\(n == 1 ? "" : "s")"
        case .time:
            let m = Int(v.rounded())
            return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
        case .saved: return "\u{20AA}\(Int(v.rounded()))"
        }
    }

    /// The reference lines: a round step (1, 2, 2.5, 5 × 10ⁿ) giving up to three lines under the tallest bar
    public static func references(max: Double) -> [Double] {
        guard max > 0 else { return [] }
        let raw = max / 3
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0].map { $0 * magnitude }.last { $0 <= raw + 1e-9 } ?? raw
        var out: [Double] = []
        var v = step
        while v <= max + 1e-9, out.count < 3 {
            out.append(v)
            v += step
        }
        return out
    }

    /// The day values of one metric (time in minutes)
    static func dayValues(_ t: StatsTotals, _ metric: PastWeeksMetric) -> [Double] {
        switch metric {
        case .km: return t.barsKm
        case .rides: return t.barsRides.count == t.barsKm.count ? t.barsRides : t.barsKm.map { _ in 0 }
        case .time: return t.barsSeconds.count == t.barsKm.count ? t.barsSeconds.map { $0 / 60 } : t.barsKm.map { _ in 0 }
        case .saved: return t.barsSaved.count == t.barsKm.count ? t.barsSaved.map { max(0, $0) } : t.barsKm.map { _ in 0 }
        }
    }

    public static func make(_ t: StatsTotals, metric: PastWeeksMetric, period p: StatsPeriod, span: StatsSpan, mode: StatsMode,
                            utcOffsetMin: Int) -> StatsChartData {
        let grouped = StatsCalc.chartBars(barsKm: dayValues(t, metric), period: p, span: span, mode: mode, utcOffsetMin: utcOffsetMin)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: utcOffsetMin * 60)
        var bars: [StatsChartBar] = []
        for (i, v) in grouped.values.enumerated() {
            let label = grouped.labels.indices.contains(i) ? grouped.labels[i] : ""
            let date: String
            if span == .year {
                if mode == .calendar {
                    df.dateFormat = "MMM"
                    var c = Calendar(identifier: .gregorian)
                    c.timeZone = df.timeZone
                    let year = c.component(.year, from: Date(timeIntervalSince1970: Double(p.startMs) / 1000 + 86_400))
                    date = c.date(from: DateComponents(year: year, month: i + 1, day: 15)).map { df.string(from: $0) } ?? label
                } else {
                    df.dateFormat = "MMM"
                    let n = max(1, grouped.values.count)
                    let mid = p.startMs + Int64(Double(p.dayCount) * (Double(i) + 0.5) / Double(n) * Double(OutsideTime.dayMs))
                    date = df.string(from: Date(timeIntervalSince1970: Double(mid) / 1000))
                }
            } else {
                df.dateFormat = "d MMM"
                date = df.string(from: Date(timeIntervalSince1970: Double(p.startMs + Int64(i) * OutsideTime.dayMs + OutsideTime.dayMs / 2) / 1000))
            }
            bars.append(StatsChartBar(value: v, axisLabel: label, dateText: date))
        }
        let maxV = bars.map(\.value).max() ?? 0
        return StatsChartData(title: title(metric, span: span), bars: bars, references: references(max: maxV), metric: metric)
    }
}
