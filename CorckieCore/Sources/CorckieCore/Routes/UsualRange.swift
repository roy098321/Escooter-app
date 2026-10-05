import Foundation

/// What the route statistics need of one ride on a route (M2-03).
public struct RouteRideStats: Equatable, Sendable {
    public var rideId: String
    public var startAt: Int64
    public var utcOffsetMin: Int
    public var variantId: String?
    public var totalS: Double?
    public var distanceM: Double?
    public var avgMovingMps: Double?
    public var usedPct: Double?
    public var elevGainM: Double?
    public var elevLossM: Double?
    /// Smart-prompt answer "not typical" (M4); excluded from every usual range
    public var excluded: Bool
    /// Wind level and wet flag exist from M4 (nil until then)
    public var windLevel: String?
    public var wet: String?

    public init(rideId: String, startAt: Int64, utcOffsetMin: Int = 0, variantId: String? = nil, totalS: Double? = nil,
                distanceM: Double? = nil, avgMovingMps: Double? = nil, usedPct: Double? = nil, elevGainM: Double? = nil,
                elevLossM: Double? = nil, excluded: Bool = false, windLevel: String? = nil, wet: String? = nil) {
        self.rideId = rideId
        self.startAt = startAt
        self.utcOffsetMin = utcOffsetMin
        self.variantId = variantId
        self.totalS = totalS
        self.distanceM = distanceM
        self.avgMovingMps = avgMovingMps
        self.usedPct = usedPct
        self.elevGainM = elevGainM
        self.elevLossM = elevLossM
        self.excluded = excluded
        self.windLevel = windLevel
        self.wet = wet
    }

    public var weekday: Int { DayClock.weekday(startAtMs: startAt, utcOffsetMin: utcOffsetMin) }
    public var minuteOfDay: Int { DayClock.minuteOfDay(startAtMs: startAt, utcOffsetMin: utcOffsetMin) }
    public var rushHour: Bool { DayClock.isRushHour(weekday: weekday, minuteOfDay: minuteOfDay) }
    public var dayType: String { DayClock.dayType(weekday: weekday) }

    /// Battery % per km, nil under 1 km (T43)
    public var pctPerKm: Double? {
        guard let used = usedPct, let d = distanceM, d >= 1_000 else { return nil }
        return used / (d / 1000)
    }
}

/// The six route stats (CONCEPT: Time, Distance, Avg. speed, Battery, Battery / km, Elevation)
public enum RouteMetric: String, CaseIterable, Sendable {
    case time, distance, avgSpeed, battery, batteryPerKm, elevation

    public func value(_ r: RouteRideStats) -> Double? {
        switch self {
        case .time: return r.totalS
        case .distance: return r.distanceM
        case .avgSpeed: return r.avgMovingMps.map { $0 * 3.6 }
        case .battery: return r.usedPct
        case .batteryPerKm: return r.pctPerKm
        case .elevation: return r.elevGainM
        }
    }

    /// Rides needed before the stat is shown as a range (T67): battery stats need 5, the rest 3
    public var gate: Int {
        switch self {
        case .battery, .batteryPerKm: return T.t67EnoughBatteryRides
        default: return T.t67EnoughTimeRides
        }
    }
}

/// A usual range: the middle 80% (10th–90th percentile), or min–max under 5 rides.
public struct UsualRangeValue: Equatable, Sendable {
    public var lo: Double
    public var hi: Double
    public var median: Double
    public var n: Int
    /// true = min–max ("based on N rides", fewer than 5)
    public var full: Bool
    public var width: Double { hi - lo }

    public init(lo: Double, hi: Double, median: Double, n: Int, full: Bool) {
        self.lo = lo
        self.hi = hi
        self.median = median
        self.n = n
        self.full = full
    }
}

public enum UsualRange {
    /// M13 / T64: the route's rides in the last 90 days, the newest 20, not excluded.
    public static func select(_ rides: [RouteRideStats], nowMs: Int64) -> [RouteRideStats] {
        let cutoff = nowMs - Int64(T.t64UsualRangeDays * 86_400_000)
        let recent = rides.filter { !$0.excluded && $0.startAt >= cutoff && $0.startAt <= nowMs + 86_400_000 }
        return Array(recent.sorted { $0.startAt > $1.startAt }.prefix(T.t64UsualRangeRides))
    }

    /// Linear interpolation between ranks (type 7); `sorted` must be ascending and not empty.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        if sorted.count == 1 { return sorted[0] }
        let pos = p * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(sorted.count - 1, lo + 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    public static func range(_ values: [Double]) -> UsualRangeValue? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let median = Geo.median(s) ?? s[0]
        if s.count < T.t64FullRangeBelowRides {
            return UsualRangeValue(lo: s[0], hi: s[s.count - 1], median: median, n: s.count, full: true)
        }
        let lowShare = (1 - T.t64UsualRangeMiddle) / 2
        return UsualRangeValue(lo: percentile(s, lowShare), hi: percentile(s, 1 - lowShare), median: median, n: s.count, full: false)
    }

    /// The range of one stat over the selected rides; nil until the stat's gate is met (T67)
    public static func range(of metric: RouteMetric, rides: [RouteRideStats]) -> UsualRangeValue? {
        let values = rides.compactMap { metric.value($0) }
        guard values.count >= metric.gate else { return nil }
        return range(values)
    }

    /// Rides with a value for the stat, and how many the gate needs: for "2 of 3 rides" (pattern D)
    public static func progress(of metric: RouteMetric, rides: [RouteRideStats]) -> (have: Int, need: Int) {
        (rides.compactMap { metric.value($0) }.count, metric.gate)
    }

    // MARK: Split (T65)

    public struct Split: Equatable, Sendable {
        /// "rush hour"
        public var factor: String
        public var with: UsualRangeValue
        public var without: UsualRangeValue
    }

    /// Two ranges when the time range is wide (> 40% of the median) and the rush-hour flag splits the rides into two groups
    /// of at least 3 whose medians each lie outside the other group's range (decision 15).
    public static func timeSplit(_ rides: [RouteRideStats]) -> Split? {
        let times = rides.filter { $0.totalS != nil }
        guard let all = range(times.compactMap { $0.totalS }), all.n >= 2 * T.t65RangeSplitGroup else { return nil }
        guard all.width > T.t65RangeSplitWidth * all.median else { return nil }
        let a = times.filter { $0.rushHour }.compactMap { $0.totalS }
        let b = times.filter { !$0.rushHour }.compactMap { $0.totalS }
        guard a.count >= T.t65RangeSplitGroup, b.count >= T.t65RangeSplitGroup,
              let ra = range(a), let rb = range(b) else { return nil }
        let apart = (ra.median < rb.lo || ra.median > rb.hi) && (rb.median < ra.lo || rb.median > ra.hi)
        return apart ? Split(factor: "rush hour", with: ra, without: rb) : nil
    }

    // MARK: Noticeably different (M14, T66)

    public enum Difference: Equatable, Sendable {
        case within
        case below(by: Double)
        case above(by: Double)
    }

    /// Outside the usual range **and** at least T66 (1 min or 2%; for battery 1 percentage point or 2%) from the nearest edge.
    /// A route with fewer than 5 rides never says it (M14). `unit` = seconds for time, points for battery.
    public static func noticeablyDifferent(value: Double, range: UsualRangeValue, minimumStep: Double) -> Difference {
        guard range.n >= T.t64FullRangeBelowRides else { return .within }
        if value > range.hi {
            let by = value - range.hi
            return by >= minimumStep || by >= range.hi * T.t66DifferentPct / 100 ? .above(by: by) : .within
        }
        if value < range.lo {
            let by = range.lo - value
            return by >= minimumStep || by >= range.lo * T.t66DifferentPct / 100 ? .below(by: by) : .within
        }
        return .within
    }

    /// For time, the minimum step is T66's 60 s; for battery 1 percentage point.
    public static let minimumTimeStepS = T.t66DifferentS
    public static let minimumBatteryStepPct = 1.0
}
