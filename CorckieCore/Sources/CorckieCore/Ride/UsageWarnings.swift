import Foundation

/// V-U1 (batch 3): where "above usual" (Level 1) and "extreme" (Level 2) start, from the rider's own rides on this route (or recent rides).
/// Level 1 = the rider's 9-in-10 line (p90 of %/km vs the median), never under +10 %. Level 2 = about double the rider's worst-ever
/// deviation (held over 2 km in the ride), at least 10 points above Level 1. Under 10 rides: +15 % / +40 %. Owner, 4 Nov, from his
/// 28 rides (median 2.66 %/km, p90 +12 %, worst +16 %).
public struct UsageLines: Equatable, Sendable {
    public var level1Share: Double
    public var level2Share: Double
    public var fromRides: Int

    public static let minRides = 10
    public static let newRiderLevel1 = 0.15
    public static let newRiderLevel2 = 0.40
    public static let level1Floor = 0.10
    public static let level2AboveLevel1 = 0.10

    public init(level1Share: Double, level2Share: Double, fromRides: Int) {
        self.level1Share = level1Share
        self.level2Share = level2Share
        self.fromRides = fromRides
    }

    public static let newRider = UsageLines(level1Share: newRiderLevel1, level2Share: newRiderLevel2, fromRides: 0)

    /// From the %/km of past rides (excluded rides already left out)
    public static func from(perKm: [Double]) -> UsageLines {
        let v = perKm.filter { $0 > 0 && $0.isFinite }.sorted()
        guard v.count >= minRides, let med = Geo.median(v), med > 0, let worst = v.last else {
            var l = newRider
            l.fromRides = v.count
            return l
        }
        let p90 = quantile(v, 0.9)
        let l1 = max(level1Floor, p90 / med - 1)
        let l2 = max(l1 + level2AboveLevel1, 2 * (worst / med - 1))
        return UsageLines(level1Share: l1, level2Share: l2, fromRides: v.count)
    }

    /// Linear-interpolated quantile of sorted values
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(sorted.count - 1, lo + 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }
}

/// V-U1 Level 2: watches one ride for battery use far above usual and for the fingerprints of a mechanical cause. Pure.
/// - drag (brakes / tyres): energy per km on steady stretches is high in two opposite directions (wind is only high one way)
/// - battery: the scooter's % falls much faster than the energy actually drawn explains
/// - no clear cause: the last 2 km used ≥ Level 2 above usual
public struct UsageWatch: Equatable, Sendable {
    public enum Cause: String, Equatable, Sendable { case drag, battery, unknown }

    /// The Level 2 rate must hold over this much riding
    public static let windowKm = 2.0
    /// Drag: each of two opposite directions needs this much steady riding, faster than `steadyKmh`
    public static let dragMinKmPerSide = 0.5
    public static let steadyKmh = 10.0
    /// Drag fires a little below the Level 2 line when the pattern is clear (both directions high)
    public static let dragShareOfLevel2 = 0.75
    /// Battery: the % fell at least this many points, and at least this many times the energy drawn. N4-11 (B90, owner 11 Nov:
    /// "appears almost daily, increase its threshold slightly"): 1.5 → 1.8 and 6 → 8 points, and the % is the smoothed level
    public static let drainMinPts = 8.0
    public static let drainRatio = 1.8
    /// Said again only when clearly worse: 20 more points above usual
    public static let worseBy = 0.20

    private struct Mark: Equatable, Sendable { var km: Double; var energyPct: Double; var livePct: Double? }
    private var marks: [Mark] = []
    private var lastT: Double?
    private var whUsed = 0.0
    /// Steady-stretch energy and distance per compass quarter (N, E, S, W)
    private var quarterKm = [Double](repeating: 0, count: 4)
    private var quarterPct = [Double](repeating: 0, count: 4)
    private var lastKm: Double?
    private var lastEnergyPct = 0.0
    private var saidShare: [Cause: Double] = [:]
    public private(set) var firstAtKm: Double?
    public private(set) var firstCause: Cause?

    public init() {}

    /// One second of riding. Returns a cause to say now (nil = nothing).
    public mutating func update(t: Double, rideKm: Double, livePct: Double?, powerW: Double?, speedKmh: Double?, courseDeg: Double?,
                                whPerPct: Double, usualPctPerKm: Double?, lines: UsageLines) -> Cause? {
        if let last = lastT, let p = powerW, p > 0 {
            let dt = t - last
            if dt > 0 && dt <= 5 { whUsed += p * dt / 3600 }
        }
        lastT = t
        let energyPct = whPerPct > 0 ? whUsed / whPerPct : 0
        let dKm = max(0, rideKm - (lastKm ?? rideKm))
        let prevEnergy = lastEnergyPct
        lastEnergyPct = energyPct
        lastKm = rideKm
        if let c = courseDeg, let s = speedKmh, s >= Self.steadyKmh, dKm > 0, dKm < 0.2 {
            let q = Int(((c + 45).truncatingRemainder(dividingBy: 360)) / 90) % 4
            quarterKm[q] += dKm
            quarterPct[q] += max(0, energyPct - prevEnergy)
        }
        if marks.last.map({ rideKm - $0.km >= 0.05 }) ?? true {
            marks.append(Mark(km: rideKm, energyPct: energyPct, livePct: livePct))
        }
        guard let usual = usualPctPerKm, usual > 0, rideKm >= Self.windowKm,
              let from = marks.last(where: { $0.km <= rideKm - Self.windowKm }) else { return nil }
        let km = rideKm - from.km
        guard km > 0 else { return nil }
        let share = (energyPct - from.energyPct) / km / usual - 1

        // battery: the % falls far faster than the energy drawn
        if let a = from.livePct, let b = livePct {
            let liveDrop = a - b, energyDrop = energyPct - from.energyPct
            if liveDrop >= Self.drainMinPts, energyDrop > 0, liveDrop >= Self.drainRatio * energyDrop, saidShare[.battery] == nil {
                return said(.battery, share: share, km: rideKm)
            }
        }
        // drag: two opposite directions both high
        let dragLine = lines.level2Share * Self.dragShareOfLevel2
        for (a, b) in [(0, 2), (1, 3)] where quarterKm[a] >= Self.dragMinKmPerSide && quarterKm[b] >= Self.dragMinKmPerSide {
            let ra = quarterPct[a] / quarterKm[a] / usual - 1, rb = quarterPct[b] / quarterKm[b] / usual - 1
            let s = min(ra, rb)
            if s >= dragLine, s >= (saidShare[.drag] ?? -1) + (saidShare[.drag] == nil ? 0 : Self.worseBy) {
                return said(.drag, share: s, km: rideKm)
            }
        }
        // no clear cause
        if share >= lines.level2Share, saidShare[.drag] == nil, saidShare[.battery] == nil,
           share >= (saidShare[.unknown] ?? -1) + (saidShare[.unknown] == nil ? 0 : Self.worseBy) {
            return said(.unknown, share: share, km: rideKm)
        }
        return nil
    }

    /// Level 2 was said this ride (Level 1 stays quiet from then on)
    public var anySaid: Bool { !saidShare.isEmpty }

    private mutating func said(_ c: Cause, share: Double, km: Double) -> Cause {
        saidShare[c] = share
        if firstAtKm == nil { firstAtKm = km; firstCause = c }
        return c
    }
}

/// V-U1: the note on the ride page after a Level 2 warning ("Unusual drag from km 6. Check brakes and tyres.")
public enum UsageAlarmNote {
    public static func text(kind: String, km: Double) -> String? {
        let from = "from km \(max(1, Int(km.rounded())))"
        switch kind {
        case "drag": return "Unusual drag \(from). Check brakes and tyres."
        case "drain", "far": return "Energy use higher than normal \(from)."
        default: return nil
        }
    }

    /// N4-5 (batch 4): the calmer note with the ride's rate ("Energy use higher than normal from km 6, 2.5 % per km.")
    public static func text(kind: String, km: Double, pctPerKm: Double?) -> String? {
        guard let base = text(kind: kind, km: km) else { return nil }
        guard kind == "drain" || kind == "far", let r = pctPerKm else { return base }
        return String(base.dropLast()) + ", " + String(format: "%.1f", r) + " % per km."
    }

    /// One note for the ride from the lines the voice said during it (the first Level 2 line)
    public static func insights(rideId: String, routeId: String?, said: [V09SaidLine], nowMs: Int64) -> [Insight] {
        guard let first = said.first(where: { ["drag", "drain", "far"].contains($0.kind) }),
              let text = text(kind: first.kind, km: first.numbers.rideKm,
                              pctPerKm: V09Message.rideRate(startPct: first.numbers.startPct, levelPct: first.numbers.levelPct,
                                                            rideKm: first.numbers.rideKm)) else { return [] }
        return [Insight(type: .usageAlarm, rideId: rideId, routeId: routeId, text: text, basedOnN: 1, createdAt: nowMs)]
    }
}
