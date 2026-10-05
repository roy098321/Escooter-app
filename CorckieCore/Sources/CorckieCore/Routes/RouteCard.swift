import Foundation

/// M2-04: everything on the route card is made here (text included), so the screen only draws it and the rules are
/// tested on Linux. Sections with nothing to show are left out (STATES S9); sections that are filling up say how far
/// they are (pattern D).
public enum RouteLabels {
    /// A route's own name, else "Start → End" when both places have a name, else "Route 3" (creation order).
    public static func title(customName: String?, fromName: String?, toName: String?, ordinal: Int) -> String {
        if let n = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        if let f = fromName, let t = toName, !f.isEmpty, !t.isEmpty { return "\(f) \u{2192} \(t)" }
        return "Route \(ordinal)"
    }

    public static func place(_ name: String?) -> String {
        if let n = name, !n.isEmpty { return n }
        return "Unnamed place"
    }
}

public struct RouteCardInput: Sendable {
    public var routeId: String
    public var customName: String?
    public var fromName: String?
    public var toName: String?
    public var ordinal: Int
    public var state: RouteState
    public var variants: [VariantInfo]
    public var rides: [RouteRideStats]
    /// Rides on the opposite route (B to A), for the elevation of the other direction
    public var otherDirection: [RouteRideStats]
    public var nowMs: Int64
    public var utcOffsetMin: Int

    public init(routeId: String, customName: String? = nil, fromName: String? = nil, toName: String? = nil, ordinal: Int = 1,
                state: RouteState = .saved, variants: [VariantInfo] = [], rides: [RouteRideStats] = [],
                otherDirection: [RouteRideStats] = [], nowMs: Int64, utcOffsetMin: Int = 0) {
        self.routeId = routeId
        self.customName = customName
        self.fromName = fromName
        self.toName = toName
        self.ordinal = ordinal
        self.state = state
        self.variants = variants
        self.rides = rides
        self.otherDirection = otherDirection
        self.nowMs = nowMs
        self.utcOffsetMin = utcOffsetMin
    }
}

public struct RouteStatRow: Equatable, Sendable {
    public var label: String
    /// "12-15 min", "~13 min", or "2 of 5 rides" while the stat is filling up
    public var value: String
    /// "based on 3 rides" under 5 rides, the rush-hour split line, or nil
    public var note: String?
    /// pattern D (not enough rides yet)
    public var filling: Bool
}

public struct RouteTodayStrip: Equatable, Sendable {
    public var headline: String
    public var detail: String
    public var filling: Bool
}

public struct RouteVariantRow: Equatable, Sendable {
    public var id: String
    public var name: String
    public var rides: Int
    public var timeText: String
    public var batteryText: String?
    public var isReference: Bool
}

public struct RouteElevationModel: Equatable, Sendable {
    public var thisWay: String
    public var otherWay: String
    /// The other direction has no ride yet: its numbers are this direction's, swapped
    public var otherIsEstimate: Bool
}

public struct RouteRideRow: Equatable, Sendable {
    public var rideId: String
    public var title: String
    public var timeText: String
    public var batteryText: String
}

public struct RouteMapLine: Equatable, Sendable {
    public var points: [GeoPoint]
    /// The reference variant is solid, the others dashed (decision 19)
    public var dashed: Bool
}

public struct RouteCardModel: Equatable, Sendable {
    public var title: String
    /// "Saved route · based on 14 rides"
    public var subtitle: String
    public var saved: Bool
    public var map: [RouteMapLine]
    public var stats: [RouteStatRow]
    public var today: RouteTodayStrip
    public var variants: [RouteVariantRow]
    public var elevation: RouteElevationModel?
    public var rides: [RouteRideRow]
    public var totalRides: Int
    /// Ride times in minutes, oldest first (the last 10), for the trend line
    public var trendMin: [Double]
}

public enum RouteCardBuilder {
    static let dash = "\u{2013}"

    public static func build(_ input: RouteCardInput) -> RouteCardModel {
        let title = RouteLabels.title(customName: input.customName, fromName: input.fromName, toName: input.toName, ordinal: input.ordinal)
        let selected = UsualRange.select(input.rides, nowMs: input.nowMs)
        let total = input.rides.count
        let kind = input.state == .saved ? "Saved route" : "Suggested route"
        let subtitle = "\(kind) \u{00B7} based on \(total) \(total == 1 ? "ride" : "rides")"

        // map: the reference variant solid, the others dashed
        var lines: [RouteMapLine] = []
        for v in input.variants.sorted(by: { $0.isReference && !$1.isReference }) where v.path.count >= 2 {
            lines.append(RouteMapLine(points: v.path, dashed: !v.isReference))
        }

        // six stats as ranges
        let split = UsualRange.timeSplit(selected)
        var stats: [RouteStatRow] = []
        for metric in RouteMetric.allCases {
            let label = Self.label(metric)
            if let r = UsualRange.range(of: metric, rides: selected) {
                var note: String?
                if r.full { note = "based on \(r.n) \(r.n == 1 ? "ride" : "rides")" }
                if metric == .time, let s = split {
                    let factorText = s.factor.prefix(1).uppercased() + String(s.factor.dropFirst())
                    note = "\(factorText) \(rangeText(.time, s.with)), otherwise \(rangeText(.time, s.without))"
                }
                stats.append(RouteStatRow(label: label, value: rangeText(metric, r), note: note, filling: false))
            } else {
                let p = UsualRange.progress(of: metric, rides: selected)
                if metric == .elevation && p.have == 0 { continue }      // no barometer data at all: hide (S9)
                stats.append(RouteStatRow(label: label, value: "\(p.have) of \(p.need) rides", note: nil, filling: true))
            }
        }

        // Today strip (M26)
        let today: RouteTodayStrip
        switch TodayEstimator.estimate(rides: input.rides, nowMs: input.nowMs, utcOffsetMin: input.utcOffsetMin) {
        case .notEnough(let have, let need):
            today = RouteTodayStrip(headline: "Today: not enough data yet", detail: "\(have) of \(need) rides so far", filling: true)
        case .estimate(let e):
            let head: String
            if let w = e.widerRangeS {
                head = "Today: \(minutes(w.lowerBound))\(dash)\(minutes(w.upperBound)) min"
            } else {
                head = "Today: ~\(minutes(e.timeS)) min"
            }
            var detail = "Based on \(e.basedOn) rides \u{00B7} leaving \(DayClock.clockText(minuteOfDay: e.departureMinute))"
            if e.rushHour { detail += " (rush hour)" }
            if let u = e.usedPct { detail += " \u{00B7} ~\(Int(u.rounded()))% battery" }
            today = RouteTodayStrip(headline: head, detail: detail, filling: false)
        }

        // variants: shown from two on (S9)
        var variantRows: [RouteVariantRow] = []
        if input.variants.count >= 2 {
            for v in input.variants {
                let rs = selected.filter { $0.variantId == v.id }
                let all = input.rides.filter { $0.variantId == v.id }
                var timeText = "\(all.count) \(all.count == 1 ? "ride" : "rides")"
                if let r = UsualRange.range(of: .time, rides: rs) { timeText = rangeText(.time, r) }
                var batteryText: String?
                if let r = UsualRange.range(of: .battery, rides: rs) { batteryText = rangeText(.battery, r) }
                variantRows.append(RouteVariantRow(id: v.id, name: v.name, rides: all.count, timeText: timeText,
                                                   batteryText: batteryText, isReference: v.isReference))
            }
        }

        // elevation both ways (M10 S3: provisional, "~")
        var elevation: RouteElevationModel?
        let gains = selected.compactMap { $0.elevGainM }
        let losses = selected.compactMap { $0.elevLossM }
        if !gains.isEmpty {
            let up = Geo.median(gains) ?? 0
            let down = Geo.median(losses) ?? 0
            let from = RouteLabels.place(input.fromName)
            let to = RouteLabels.place(input.toName)
            let other = UsualRange.select(input.otherDirection, nowMs: input.nowMs)
            let oUp = Geo.median(other.compactMap { $0.elevGainM })
            let oDown = Geo.median(other.compactMap { $0.elevLossM })
            let thisWay = "\(from) \u{2192} \(to): \(elevText(up: up, down: down))"
            if let oUp {
                elevation = RouteElevationModel(thisWay: thisWay, otherWay: "\(to) \u{2192} \(from): \(elevText(up: oUp, down: oDown ?? 0))",
                                                otherIsEstimate: false)
            } else {
                elevation = RouteElevationModel(thisWay: thisWay, otherWay: "\(to) \u{2192} \(from): \(elevText(up: down, down: up)) (estimate)",
                                                otherIsEstimate: true)
            }
        }

        // rides list + trend
        let newestFirst = input.rides.sorted { $0.startAt > $1.startAt }
        var rows: [RouteRideRow] = []
        for r in newestFirst.prefix(5) {
            var timeText = dash
            if let t = r.totalS { timeText = RideSummaryBuilder.duration(t) }
            var batteryText = dash
            if let u = r.usedPct { batteryText = "\(Int(u.rounded()))%" }
            rows.append(RouteRideRow(rideId: r.rideId, title: RideSummaryBuilder.title(startAt: r.startAt, utcOffsetMin: r.utcOffsetMin),
                                     timeText: timeText, batteryText: batteryText))
        }
        var trend: [Double] = []
        for r in newestFirst.prefix(10).reversed() {
            if let t = r.totalS { trend.append(t / 60) }
        }

        return RouteCardModel(title: title, subtitle: subtitle, saved: input.state == .saved, map: lines, stats: stats, today: today,
                              variants: variantRows, elevation: elevation, rides: rows, totalRides: total, trendMin: trend)
    }

    // MARK: Text

    static func label(_ m: RouteMetric) -> String {
        switch m {
        case .time: return "Time"
        case .distance: return "Distance"
        case .avgSpeed: return "Avg. speed"
        case .battery: return "Battery"
        case .batteryPerKm: return "Battery / km"
        case .elevation: return "Elevation"
        }
    }

    static func minutes(_ s: Double) -> Int { Int((s / 60).rounded()) }

    static func elevText(up: Double, down: Double) -> String {
        "~+\(Int(up.rounded())) m / \u{2212}\(Int(down.rounded())) m"
    }

    /// "12\u{2013}15 min", or "~13 min" when both ends round to the same number
    public static func rangeText(_ metric: RouteMetric, _ r: UsualRangeValue) -> String {
        func pair(_ a: String, _ b: String, _ unit: String) -> String {
            a == b ? "~\(a)\(unit)" : "\(a)\(dash)\(b)\(unit)"
        }
        switch metric {
        case .time:
            if r.hi >= 3_600 { return RideSummaryBuilder.duration(r.lo) + " " + dash + " " + RideSummaryBuilder.duration(r.hi) }
            return pair("\(minutes(r.lo))", "\(minutes(r.hi))", " min")
        case .distance:
            return pair(String(format: "%.1f", r.lo / 1000), String(format: "%.1f", r.hi / 1000), " km")
        case .avgSpeed:
            return pair("\(Int(r.lo.rounded()))", "\(Int(r.hi.rounded()))", " km/h")
        case .battery:
            return pair("\(Int(r.lo.rounded()))", "\(Int(r.hi.rounded()))", "%")
        case .batteryPerKm:
            return pair(String(format: "%.1f", r.lo), String(format: "%.1f", r.hi), "%/km")
        case .elevation:
            let a = Int(r.lo.rounded())
            let b = Int(r.hi.rounded())
            return a == b ? "~+\(a) m" : "~+\(a)\(dash)\(b) m"
        }
    }
}
