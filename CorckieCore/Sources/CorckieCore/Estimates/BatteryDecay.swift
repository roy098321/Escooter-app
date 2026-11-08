import Foundation

/// V-U2 (batch 3): battery decay in real-world km. Owner, 4 Nov:
/// - a notice at every 5 % of health lost from 90 %: 90 / 85 Low "Battery decay detected", 80 / 75 Medium "Battery wearing",
///   70 and every 5 below High "Battery worn"; each level once
/// - health compares 3-month stretches of rides in similar weather (cold looks like wear), the "new" baseline starts after the
///   early settling dip, and a level counts only when it holds for 2 weeks
/// - the report leads with km on a full battery (P-8), health % next to it
public struct DecayRide: Equatable, Sendable {
    public var startAt: Int64
    public var distanceM: Double
    public var usedPct: Double
    public var airTempC: Double?

    public init(startAt: Int64, distanceM: Double, usedPct: Double, airTempC: Double? = nil) {
        self.startAt = startAt
        self.distanceM = distanceM
        self.usedPct = usedPct
        self.airTempC = airTempC
    }

    /// km on a full battery (100 %) this ride shows
    public var kmPerFull: Double { distanceM / 1000 / usedPct * 100 }
}

public enum DecaySeverity: String, Equatable, Sendable {
    case low, medium, high

    public var title: String {
        switch self {
        case .low: return "Battery decay detected"
        case .medium: return "Battery wearing"
        case .high: return "Battery worn"
        }
    }
}

public struct DecayPoint: Equatable, Sendable {
    public var atMs: Int64
    public var km: Double
    public var healthPct: Double
}

public struct DecayReport: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Not enough yet: about this many weeks more; the range seen so far (nil = none)
        case learning(weeksLeft: Int, kmSoFar: Double?)
        case ready
    }
    public var state: State
    public var newKm: Double?
    public var nowKm: Double?
    public var healthPct: Double?
    /// The level reached (90, 85, …) once it held for 2 weeks; nil = none yet
    public var level: Int?
    public var points: [DecayPoint]
    /// km of range lost per year (positive = losing), nil = too early to tell
    public var losingKmPerYear: Double?
    /// The next level, its km and roughly when (epoch ms; nil = not foreseeable)
    public var nextLevel: Int?
    public var nextLevelKm: Double?
    public var nextLevelAtMs: Int64?
    public var cycles: Double

    public var severity: DecaySeverity? { level.map(BatteryDecay.severity(level:)) }
}

public enum BatteryDecay {
    /// A ride shows the range only when it used enough battery
    public static let minUsedPct = 10.0
    /// The early settling dip: the baseline starts after this many equivalent cycles
    public static let settleCycles = 20.0
    /// Baseline and "now" are each this long
    public static let windowDays = 90.0
    /// Similar-weather references: the first year after settling
    public static let baselineYearDays = 365.0
    public static let minBaselineRides = 10
    public static let minNowRides = 8
    /// Similar weather: rides within this many °C of each other are compared
    public static let tempBandC = 5.0
    /// A level counts only when it also held this long ago
    public static let holdDays = 14.0
    public static let firstLevel = 90
    public static let step = 5

    static let dayMs: Int64 = 86_400_000

    public static func severity(level: Int) -> DecaySeverity {
        level >= 85 ? .low : (level >= 75 ? .medium : .high)
    }

    /// The level a health reaches: 88 → 90, 85 → 85, 84.9 → 85; nil above 90
    public static func level(health: Double) -> Int? {
        let l = Int((health / Double(step)).rounded(.up)) * step
        return l <= firstLevel ? l : nil
    }

    /// The report at `nowMs`. `resetAtMs`: "I replaced the battery" (rides before it are ignored).
    public static func report(rides all: [DecayRide], nowMs: Int64, resetAtMs: Int64? = nil) -> DecayReport {
        let rides = all.filter { $0.usedPct > 0 && $0.distanceM > 0 && (resetAtMs == nil || $0.startAt >= resetAtMs!) }
            .sorted { $0.startAt < $1.startAt }
        let cycles = rides.reduce(0) { $0 + $1.usedPct } / 100
        let usable = rides.filter { $0.usedPct >= minUsedPct }
        let kmSoFar = Geo.median(usable.map(\.kmPerFull))
        var report = DecayReport(state: .learning(weeksLeft: 0, kmSoFar: kmSoFar), points: [], cycles: cycles)

        // the baseline: the first 90 days of rides after the settling cycles
        var used = 0.0
        var settleAt: Int64?
        for r in rides {
            used += r.usedPct / 100
            if used >= settleCycles { settleAt = r.startAt; break }
        }
        guard let start = settleAt else {
            let perWeek = cyclesPerWeek(rides)
            let weeks = perWeek > 0 ? Int(((settleCycles - cycles) / perWeek + windowDays / 7 * 2).rounded(.up)) : 26
            report.state = .learning(weeksLeft: max(1, weeks), kmSoFar: kmSoFar)
            return report
        }
        let baseEnd = start + Int64(windowDays) * dayMs
        // "new" = the first 3 months; the similar-weather references come from the whole first year (every season once)
        let firstMonths = usable.filter { $0.startAt >= start && $0.startAt < baseEnd }
        let baseline = usable.filter { $0.startAt >= start && $0.startAt < start + Int64(baselineYearDays) * dayMs }
        let nowRides = usable.filter { $0.startAt >= max(baseEnd, nowMs - Int64(windowDays) * dayMs) && $0.startAt <= nowMs }
        guard nowMs >= baseEnd, firstMonths.count >= minBaselineRides, let newKm = Geo.median(firstMonths.map(\.kmPerFull)) else {
            let daysLeft = Double(max(0, baseEnd - nowMs)) / Double(dayMs) + windowDays / 3
            report.state = .learning(weeksLeft: max(1, Int((daysLeft / 7).rounded(.up))), kmSoFar: kmSoFar)
            return report
        }
        report.newKm = newKm
        guard nowRides.count >= minNowRides, let health = health(nowRides, baseline: baseline) else {
            report.state = .learning(weeksLeft: 2, kmSoFar: kmSoFar)
            return report
        }
        report.state = .ready
        report.healthPct = health
        report.nowKm = newKm * health / 100

        // the level counts when it also held 2 weeks ago
        let earlierAt = nowMs - Int64(holdDays) * dayMs
        let earlierRides = usable.filter { $0.startAt >= max(baseEnd, earlierAt - Int64(windowDays) * dayMs) && $0.startAt <= earlierAt }
        if let lNow = level(health: health), earlierRides.count >= minNowRides,
           let hThen = Self.health(earlierRides, baseline: baseline), let lThen = level(health: hThen) {
            report.level = max(lNow, lThen)
        }

        // the curve: 100 % at the start, then one point a month (each from the 3 months up to it)
        var points = [DecayPoint(atMs: start, km: newKm, healthPct: 100)]
        var at = baseEnd
        while at <= nowMs {
            let win = usable.filter { $0.startAt > at - Int64(windowDays) * dayMs && $0.startAt <= at && $0.startAt >= baseEnd }
            if win.count >= minNowRides / 2, let h = Self.health(win, baseline: baseline) {
                points.append(DecayPoint(atMs: at, km: newKm * h / 100, healthPct: h))
            }
            at += 30 * dayMs
        }
        if points.last?.atMs != nowMs { points.append(DecayPoint(atMs: nowMs, km: newKm * health / 100, healthPct: health)) }
        report.points = points

        // trend and the next level
        if points.count >= 3, let first = points.first, let last = points.last, last.atMs - first.atMs >= 60 * dayMs {
            let slopePctPerDay = Self.slope(points.map { (Double($0.atMs - first.atMs) / Double(dayMs), $0.healthPct) })
            report.losingKmPerYear = -slopePctPerDay * 365 * newKm / 100
            let next = (report.level.map { $0 - step } ?? (level(health: health).map { $0 - step } ?? firstLevel))
            report.nextLevel = next
            report.nextLevelKm = newKm * Double(next) / 100
            if slopePctPerDay < 0 {
                let days = (Double(next) - health) / slopePctPerDay
                report.nextLevelAtMs = nowMs + Int64(max(0, days) * Double(dayMs))
            }
        }
        return report
    }

    /// Health % of `rides` against the baseline, ride by ride against baseline rides in similar weather
    static func health(_ rides: [DecayRide], baseline: [DecayRide]) -> Double? {
        guard let all = Geo.median(baseline.map(\.kmPerFull)), all > 0 else { return nil }
        let ratios: [Double] = rides.compactMap { r in
            var ref = all
            if let t = r.airTempC {
                let near = baseline.filter { b in b.airTempC.map { abs($0 - t) <= tempBandC } ?? false }
                if near.count >= 3, let m = Geo.median(near.map(\.kmPerFull)) { ref = m }
                else if baseline.contains(where: { $0.airTempC != nil }) {
                    // weather the baseline never saw: compare only when it is close to the baseline's range
                    let temps = baseline.compactMap(\.airTempC)
                    if let lo = temps.min(), let hi = temps.max(), t < lo - tempBandC || t > hi + tempBandC { return nil }
                }
            }
            return r.kmPerFull / ref
        }
        guard ratios.count >= max(3, rides.count / 2), let m = Geo.median(ratios) else { return nil }
        return m * 100
    }

    static func cyclesPerWeek(_ rides: [DecayRide]) -> Double {
        guard let a = rides.first?.startAt, let b = rides.last?.startAt, b > a else { return 0 }
        let weeks = Double(b - a) / Double(dayMs) / 7
        return weeks > 0 ? rides.reduce(0) { $0 + $1.usedPct } / 100 / weeks : 0
    }

    /// Least-squares slope of (x, y)
    static func slope(_ xy: [(Double, Double)]) -> Double {
        let n = Double(xy.count)
        let mx = xy.reduce(0) { $0 + $1.0 } / n, my = xy.reduce(0) { $0 + $1.1 } / n
        let num = xy.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let den = xy.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        return den > 0 ? num / den : 0
    }

    /// The notice to send now: the deepest level reached that was not sent yet (nil = nothing new)
    public static func noticeLevel(report: DecayReport, sent: Set<Int>) -> Int? {
        guard let l = report.level, !sent.contains(l) else { return nil }
        return l
    }

    /// The notification's words (P-8: km first)
    public static func notice(level: Int, report: DecayReport) -> (title: String, body: String) {
        let s = severity(level: level)
        let km = report.nowKm.map { "\(Int($0.rounded())) km" } ?? "less"
        let new = report.newKm.map { " (new: \(Int($0.rounded())) km)" } ?? ""
        let health = report.healthPct.map { Int($0.rounded()) } ?? level
        var body = "A full battery now takes you about \(km)\(new) \u{00B7} health \(health) %."
        if s == .high { body += " Consider replacing the battery." }
        return (s.title, body)
    }
}
