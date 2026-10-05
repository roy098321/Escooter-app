import Foundation

/// M26: today's estimate for a route. `time` is the honest number shown; `neededPct` carries the 10% margin (T101, policy
/// P-1) and is only for decisions (greying, there-and-back, ride-start warning), never displayed as the estimate.
public struct TodayEstimate: Equatable, Sendable {
    /// Seconds (route median of the matching group + factor effects)
    public var timeS: Double
    /// Set when the confirmation (median of similar past rides) disagrees by more than the usual range width: show a range, not "~value"
    public var widerRangeS: ClosedRange<Double>?
    /// Battery % used, nil until the battery gate (5 rides) is met
    public var usedPct: Double?
    /// usedPct x 1.10 (T101): what decisions use
    public var neededPct: Double?
    public var basedOn: Int
    /// Departure minute of day the estimate is for
    public var departureMinute: Int
    public var rushHour: Bool
    /// Factor effects were added (none in M2: they arrive with M4)
    public var factorsApplied: Bool
}

public enum TodayResult: Equatable, Sendable {
    /// Fewer than 3 rides (T67): pattern D, "2 of 3 rides"
    case notEnough(have: Int, need: Int)
    case estimate(TodayEstimate)
}

public enum TodayEstimator {
    /// - Parameters:
    ///   - rides: all rides stored on the route
    ///   - nowMs / utcOffsetMin: today, for the day type
    ///   - departureMinute: the minute of day to leave (Arrive by, M29); nil = the usual departure for this route and day type
    ///   - timeEffectS / usedEffectPct: the sum of factor effects for today's forecast (M24; zero until M4)
    ///   - windLevel: today's wind level for the confirmation (nil until M4)
    public static func estimate(rides: [RouteRideStats], nowMs: Int64, utcOffsetMin: Int, departureMinute: Int? = nil,
                                timeEffectS: Double = 0, usedEffectPct: Double = 0, windLevel: String? = nil) -> TodayResult {
        let selected = UsualRange.select(rides, nowMs: nowMs)
        let timed = selected.filter { $0.totalS != nil }
        guard timed.count >= T.t67EnoughTimeRides else { return .notEnough(have: timed.count, need: T.t67EnoughTimeRides) }

        let weekday = DayClock.weekday(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)
        let dayType = DayClock.dayType(weekday: weekday)

        // usual departure for this route and day type, else any ride's, else now
        let sameDay = timed.filter { $0.dayType == dayType }.map { Double($0.minuteOfDay) }
        let departure = departureMinute
            ?? Geo.median(sameDay).map { Int($0.rounded()) }
            ?? Geo.median(timed.map { Double($0.minuteOfDay) }).map { Int($0.rounded()) }
            ?? DayClock.minuteOfDay(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)
        let rush = DayClock.isRushHour(weekday: weekday, minuteOfDay: departure)

        // the matching split group (T65), or all the rides
        var group = timed
        if UsualRange.timeSplit(timed) != nil {
            group = timed.filter { $0.rushHour == rush }
        }
        let times = group.compactMap { $0.totalS }
        guard let groupRange = UsualRange.range(times) else { return .notEnough(have: timed.count, need: T.t67EnoughTimeRides) }
        let today = groupRange.median + timeEffectS

        // confirmation: the median of past rides in similar conditions (same rush-hour flag, same wind level when both are known)
        var wider: ClosedRange<Double>?
        let similar = timed.filter { r in
            r.rushHour == rush && (windLevel == nil || r.windLevel == nil || r.windLevel == windLevel)
        }.compactMap { $0.totalS }
        if similar.count >= T.t67EnoughTimeRides, let conf = Geo.median(similar), abs(today - conf) > groupRange.width {
            wider = min(today, conf, groupRange.lo)...max(today, conf, groupRange.hi)
        }

        // battery: the same group when it has 5 rides with a value, else all selected rides with one
        var used: Double?
        let groupUsed = group.compactMap { $0.usedPct }
        let allUsed = timed.compactMap { $0.usedPct }
        if groupUsed.count >= T.t67EnoughBatteryRides {
            used = Geo.median(groupUsed)
        } else if allUsed.count >= T.t67EnoughBatteryRides {
            used = Geo.median(allUsed)
        }
        if let u = used { used = max(0, u + usedEffectPct) }
        return .estimate(TodayEstimate(timeS: today, widerRangeS: wider, usedPct: used, neededPct: used.map(SafetyMargin.forDecision),
                                       basedOn: timed.count, departureMinute: departure, rushHour: rush,
                                       factorsApplied: timeEffectS != 0 || usedEffectPct != 0))
    }
}
