import Foundation

// M3-02 · CALC_SPEC M30 (charge log), M31 (cycles), M32 (battery health). The scooter switches itself off while it
// charges, so a charge is never watched: it is found between two rides, from a rested % that is higher than where the
// previous ride ended. Honest numbers only; the 10% decision margin (T101) is never in here.

/// One ride as the charge log needs it.
public struct ChargeRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var endAt: Int64?
    /// ride / shortHop / discarded
    public var kind: String
    public var isSimulated: Bool
    public var startRestPct: Double?
    public var endRestPct: Double?
    /// Last live % of the ride (reads low under load)
    public var lastLivePct: Double?
    /// The ride's battery used (rested drop, or from energy once calibrated)
    public var usedPct: Double?
    /// The scooter switched itself off (CALC_SPEC A2, endReason scooterOff)
    public var endedByScooterOff: Bool
    public var distanceM: Double?

    public init(id: String, startAt: Int64, endAt: Int64? = nil, kind: String = "ride", isSimulated: Bool = false,
                startRestPct: Double?, endRestPct: Double?, lastLivePct: Double? = nil, usedPct: Double? = nil,
                endedByScooterOff: Bool = false, distanceM: Double? = nil) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.kind = kind
        self.isSimulated = isSimulated
        self.startRestPct = startRestPct
        self.endRestPct = endRestPct
        self.lastLivePct = lastLivePct
        self.usedPct = usedPct
        self.endedByScooterOff = endedByScooterOff
        self.distanceM = distanceM
    }
}

/// One charge found between two rides (one row per pair: several charges in between are one session).
public struct DetectedCharge: Equatable, Sendable {
    public var id: String
    public var afterRideId: String
    public var beforeRideId: String
    public var fromPct: Double
    public var toPct: Double
    /// epoch ms: the previous ride's end (its switch-off moment when the scooter switched itself off) → the next start
    public var windowStartAt: Int64
    public var windowEndAt: Int64
    public var startedByShutdownFlag: Bool
    /// Away for days: counts for cycles, not for health or calibration; shown as "time unknown"
    public var inferredWhileAway: Bool
    public var isSimulated: Bool

    public var chargedPct: Double { max(0, toPct - fromPct) }
}

public enum ChargeDetector {
    /// Away for more than 3 days between two rides = "Charged while away" (STATES S14)
    public static let awayS = 3 * 86_400.0
    /// With only the live % to go on (switched off before resting), the % may recover this much from sag alone
    public static let liveSagPct = T.t41SagRecoveryPct

    /// Where the ride ended, with how sure that is: rested end, else predicted (start − used), else the live % (reads low).
    static func end(of r: ChargeRide) -> (pct: Double, riseNeeded: Double)? {
        if let e = r.endRestPct { return (e, T.t45ChargeRisePct) }
        if let s = r.startRestPct, let u = r.usedPct { return (s - u, T.t45ChargeRisePct) }
        if let l = r.lastLivePct { return (l, liveSagPct) }
        return nil
    }

    /// Charges between consecutive rides (any order in; oldest first out). Simulated and real rides are never paired.
    /// Voltage: the rested voltage is not stored yet (P5_DILEMMAS D5), so the rule is the % rise alone.
    public static func detect(_ rides: [ChargeRide]) -> [DetectedCharge] {
        var out: [DetectedCharge] = []
        for sim in [false, true] {
            let chain = rides.filter { $0.isSimulated == sim && $0.kind != "discarded" }.sorted { $0.startAt < $1.startAt }
            for i in 0..<max(0, chain.count - 1) {
                let prev = chain[i], next = chain[i + 1]
                guard let e = end(of: prev), let nextStart = next.startRestPct else { continue }
                guard nextStart >= e.pct + e.riseNeeded else { continue }
                let windowStart = prev.endAt ?? prev.startAt
                let away = Double(next.startAt - windowStart) / 1000 > awayS && !prev.endedByScooterOff
                out.append(DetectedCharge(id: "charge-\(next.id)", afterRideId: prev.id, beforeRideId: next.id,
                                          fromPct: min(100, max(0, e.pct)), toPct: min(100, nextStart),
                                          windowStartAt: windowStart, windowEndAt: next.startAt,
                                          startedByShutdownFlag: prev.endedByScooterOff, inferredWhileAway: away, isSimulated: sim))
            }
        }
        return out.sorted { $0.windowStartAt < $1.windowStartAt }
    }
}

/// M31 charge cycles.
public enum ChargeCycles {
    /// `max(Σ charged % ÷ 100, Σ used % ÷ 100)`
    public static func equivalent(charges: [DetectedCharge], rides: [ChargeRide]) -> Double {
        let charged = charges.filter { !$0.isSimulated }.reduce(0) { $0 + $1.chargedPct } / 100
        let used = rides.filter { !$0.isSimulated && $0.kind == "ride" }.reduce(0) { $0 + max(0, $1.usedPct ?? 0) } / 100
        return max(charged, used)
    }
}

/// M32 battery health: km per 100% battery, latest 3 months ÷ the first 3 months.
public struct BatteryHealth: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Not enough yet: needs 5 equivalent cycles and 20 rides
        case gathering(cycles: Double, rides: Int)
        /// 3-month windows are still the same rides: the baseline is forming, health = 100%
        case baseline(kmPer100: Double)
        case health(pct: Double, kmPer100Now: Double, kmPer100First: Double)
    }

    public static let minCycles = 5.0
    public static let minRides = 20
    /// A ride tells km per 100% only when it used enough battery
    public static let minUsedPct = 10.0
    public static let windowDays = 90.0

    public static func evaluate(rides: [ChargeRide], cycles: Double) -> State {
        let real = rides.filter { !$0.isSimulated && $0.kind == "ride" }
        guard cycles >= minCycles, real.count >= minRides else { return .gathering(cycles: cycles, rides: real.count) }
        let points: [(at: Int64, km100: Double)] = real.compactMap { r in
            guard let u = r.usedPct, u >= minUsedPct, let d = r.distanceM, d > 0 else { return nil }
            return (r.startAt, d / 1000 / u * 100)
        }.sorted { $0.at < $1.at }
        guard let first = points.first, let last = points.last else { return .gathering(cycles: cycles, rides: real.count) }
        let win = Int64(windowDays * 86_400_000)
        let early = points.filter { $0.at < first.at + win }.map(\.km100)
        let late = points.filter { $0.at > last.at - win }.map(\.km100)
        guard let e = BatteryCalibrator.median(early), let l = BatteryCalibrator.median(late), e > 0 else {
            return .gathering(cycles: cycles, rides: real.count)
        }
        if last.at - first.at < win { return .baseline(kmPer100: l) }
        return .health(pct: l / e * 100, kmPer100Now: l, kmPer100First: e)
    }
}
