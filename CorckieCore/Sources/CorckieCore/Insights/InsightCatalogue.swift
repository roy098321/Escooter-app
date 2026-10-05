import Foundation

// M4-03: the insight catalogue (CALC_SPEC 9.2, INSIGHTS.md). One pure generator per catalogue row: plain numbers in,
// `[Insight]` out (the text, "based on N rides", the size inputs). Each generator checks its gate (M15: counts with and
// without, the MAD and the pooled rare factors are already in `FactorEffect.passesGate`) and, below the gate, returns a
// *progress* item (pattern D, "2 of 3 windy rides") where the spec has one, never a guess. Generators only make candidates:
// ranking (InsightRanking) picks what shows, M4-04 decides what is sent. Q5 / Q6 stay the Arrive-by card and the arrival
// strip (M2); Q9 is the M2-09 ride-start warning, wrapped here as an insight row; Q23 is M6, heat M4-06, the smart prompt M4-05.

public enum InsightMoment: String, CaseIterable, Sendable {
    /// during the ride (banner)
    case live
    /// at ride start (stage 2): at most 2 messages, the rest to the summary
    case start
    /// on the ride summary / ride detail
    case after
    /// the week card and the Sunday notification
    case weekly
    /// route card / battery page (no new rows in v1)
    case card
    /// a notification outside a ride (budget M4-04)
    case notify
    /// made for an already seen summary (weather arrived late): Recent insights only, never the top card
    case recentOnly = "recent"
}

/// CALC_SPEC 9.3 classes (the base of the score)
public enum InsightClass: Int, Comparable, Sendable {
    case credit = 30, progress = 40, decision = 60, surprise = 80, safety = 100

    public static func < (a: InsightClass, b: InsightClass) -> Bool { a.rawValue < b.rawValue }
}

/// Where a row may appear (M4-04 / M4-07 / M4-09 / M4-10 read it)
public enum InsightPlacement: String, CaseIterable, Sendable {
    case liveBanner, home, rideDetail, notification, weekly
}

/// How an id is made, so the same insight is never stored twice (dedupe) and once-only rows stay once.
public enum InsightDedupeScope: Sendable {
    /// one per ride: "q4After:<rideId>"
    case perRide
    /// one per week: "q22Weekly:w<weekStart>"
    case perWeek
    /// one per day and subject: "q15Notify:<route>:d<day>"
    case perDay
    /// once ever per subject: "q17New:<climbId>"
    case once
}

public enum InsightType: String, CaseIterable, Sendable {
    case q1Live, q1After, q2After, q2Live, q3After, q3Verdict, q4After, q4Weekly, q9Live, q13After, q13Weekly
    case q15Live, q15After, q15Notify, q17New, q18, q19After, q22Weekly
    case firstRide, unlockTime, unlockBattery, unlockCalibration, unlockRange
    case heatPeak, heatHotDay, heatRanHotter

    public var moment: InsightMoment {
        switch self {
        case .q1Live, .q2Live, .q9Live, .q15Live: return .start
        case .q4Weekly, .q13Weekly, .q22Weekly: return .weekly
        case .q15Notify: return .notify
        default: return .after
        }
    }

    public var insightClass: InsightClass {
        switch self {
        case .q9Live, .heatPeak: return .safety
        case .q4After, .q4Weekly, .q19After, .heatHotDay, .heatRanHotter: return .surprise
        case .q1Live, .q1After, .q2After, .q2Live, .q3After, .q3Verdict, .q18, .q15Live, .q15Notify: return .decision
        case .q17New, .firstRide, .unlockTime, .unlockBattery, .unlockCalibration, .unlockRange: return .progress
        case .q13After, .q13Weekly, .q15After, .q22Weekly: return .credit
        }
    }

    public var placements: [InsightPlacement] {
        switch moment {
        case .start, .live: return [.liveBanner]
        case .weekly: return self == .q22Weekly ? [.weekly, .notification] : [.weekly]
        case .notify: return [.notification]
        default: return [.rideDetail, .home]
        }
    }

    /// C24 order for the live / start ones (the banner queue, `LiveBanner`)
    public var livePriority: LiveBanner? {
        switch self {
        case .q9Live: return .returnCheck
        case .q2Live: return .batteryTight
        case .q1Live: return .destination
        case .q15Live: return .headwind
        default: return nil
        }
    }

    public var dedupe: InsightDedupeScope {
        switch self {
        case .q4Weekly, .q13Weekly, .q22Weekly: return .perWeek
        case .q15Notify: return .perDay
        case .q3Verdict, .q17New, .firstRide, .unlockTime, .unlockBattery, .unlockCalibration, .unlockRange: return .once
        default: return .perRide
        }
    }

    /// Cooldown per subject (days): the same advice is not repeated on every ride
    public var cooldownDays: Double {
        switch self {
        case .q13After, .q18: return 14
        case .q1After, .q2After: return 2
        default: return 0
        }
    }

    /// How long the row stays valid after it was made (nil = kept: ride detail, Recent insights)
    public var lifetimeMs: Int64? {
        switch moment {
        case .start, .live: return 2 * OutsideTime.hourMs
        case .notify: return OutsideTime.dayMs
        case .weekly: return 14 * OutsideTime.dayMs
        default: return nil
        }
    }
}

public struct Insight: Equatable, Sendable {
    public var id: String
    public var type: InsightType
    public var moment: InsightMoment
    public var rideId: String?
    public var routeId: String?
    public var weekStart: Int64?
    /// What the dedupe / cooldown counts per (route, option, climb, ...)
    public var subject: String
    public var text: String
    public var basedOnN: Int
    /// Size inputs (9.3: 5 x minutes + 3 x % battery, signed as the effect)
    public var timeS: Double?
    public var usedPct: Double?
    /// Pattern D: the gate is not met yet; `text` is the progress line
    public var isProgress: Bool
    public var createdAt: Int64
    public var expiresAt: Int64?
    public var shownAt: Int64?
    public var dismissedAt: Int64?
    public var score: Double

    public init(type: InsightType, rideId: String? = nil, routeId: String? = nil, weekStart: Int64? = nil, subject: String? = nil,
                text: String, basedOnN: Int, timeS: Double? = nil, usedPct: Double? = nil, isProgress: Bool = false, createdAt: Int64) {
        self.type = type
        self.moment = type.moment
        self.rideId = rideId
        self.routeId = routeId
        self.weekStart = weekStart
        let subj = subject ?? routeId ?? rideId ?? ""
        self.subject = subj
        self.text = text
        self.basedOnN = basedOnN
        self.timeS = timeS
        self.usedPct = usedPct
        self.isProgress = isProgress
        self.createdAt = createdAt
        self.expiresAt = type.lifetimeMs.map { createdAt + $0 }
        self.score = 0
        self.id = Insight.makeId(type: type, rideId: rideId, weekStart: weekStart, subject: subj, at: createdAt, progress: isProgress)
        self.score = InsightRanking.score(self, recentTopTypes: [])
    }

    /// The deterministic id (dedupe): see `InsightDedupeScope`
    public static func makeId(type: InsightType, rideId: String?, weekStart: Int64?, subject: String, at: Int64, progress: Bool) -> String {
        let base: String
        switch type.dedupe {
        case .perRide: base = "\(type.rawValue):\(rideId ?? subject)"
        case .perWeek: base = "\(type.rawValue):w\(weekStart ?? 0)"
        case .perDay: base = "\(type.rawValue):\(subject):d\(at / OutsideTime.dayMs)"
        case .once: base = "\(type.rawValue):\(subject)"
        }
        return progress ? base + ":progress" : base
    }

    /// The `insight.type` column: "q4After", or "progress.q4After" for a pattern D line
    public var storedType: String { (isProgress ? "progress." : "") + type.rawValue }

    public static func parse(storedType: String) -> (type: InsightType, progress: Bool)? {
        let progress = storedType.hasPrefix("progress.")
        let raw = progress ? String(storedType.dropFirst("progress.".count)) : storedType
        guard let t = InsightType(rawValue: raw) else { return nil }
        return (type: t, progress: progress)
    }

    public var insightClass: InsightClass { type.insightClass }
    public var placements: [InsightPlacement] { type.placements }
    public var livePriority: LiveBanner? { type.livePriority }

    public func isExpired(at nowMs: Int64) -> Bool { expiresAt.map { nowMs >= $0 } ?? false }
}

/// Guesses the spec leaves open (P5_DILEMMAS D8, S built); reversible here.
public enum InsightRules {
    /// Q1 / Q2 / Q18: a variant "is faster" only by at least T66's 1 min; "uses less" by at least 1 point
    public static let fasterByS = T.t66DifferentS
    public static let lessBatteryByPct = 1.0
    /// Q13: a ride is "flat out" with >= 50% of moving time at the cap, "calm" with <= 20%; the route needs 9 rides (T96 row)
    public static let flatOutShare = 50.0
    public static let calmShare = 20.0
    public static let q13RouteRides = 9
    /// Q15-after / Q4: an effect under 10 s and 0.5 points is not named
    public static let nameFactorS = 10.0
    public static let nameFactorPct = 0.5
    /// Q18: variants differ by >= 8 m of climbing (9.2)
    public static let flatterByM = 8.0
    /// Q15-notify: wind picking up = forecast headwind rose by >= 10 km/h, or >= moderate (15 km/h)
    public static let windRoseKmh = 10.0
    /// Q4-weekly: a weekly factor total under 1 min and 1% is not said
    public static let weeklyMinS = 60.0
    public static let weeklyMinPct = 1.0
}

// MARK: - Inputs (plain numbers; the App layer fills them from the tables)

/// One variant of a route with its rides (Q1 / Q2 / Q18)
public struct InsightVariant: Equatable, Sendable {
    public var id: String
    public var name: String
    public var timesS: [Double]
    public var usedPct: [Double]
    public var gainM: [Double]
    public var distanceM: [Double]

    public init(id: String, name: String, timesS: [Double], usedPct: [Double] = [], gainM: [Double] = [], distanceM: [Double] = []) {
        self.id = id
        self.name = name
        self.timesS = timesS
        self.usedPct = usedPct
        self.gainM = gainM
        self.distanceM = distanceM
    }

    public var medianTimeS: Double? { Geo.median(timesS) }
    public var medianUsedPct: Double? { usedPct.count >= T.t67EnoughBatteryRides ? Geo.median(usedPct) : nil }
    public var timeRange: UsualRangeValue? { UsualRange.range(timesS) }
    public var hasTimeGate: Bool { timesS.count >= T.t91VariantRides }
    /// "via park shortcut"
    public var via: String { name.lowercased().hasPrefix("via ") ? name : "via \(name)" }
}

/// One ride for the destination guess (Q1-live, T90)
public struct DestinationRide: Equatable, Sendable {
    public var routeId: String
    public var startPlaceId: String?
    public var startAt: Int64
    public var utcOffsetMin: Int

    public init(routeId: String, startPlaceId: String?, startAt: Int64, utcOffsetMin: Int) {
        self.routeId = routeId
        self.startPlaceId = startPlaceId
        self.startAt = startAt
        self.utcOffsetMin = utcOffsetMin
    }
}

public struct DestinationGuess: Equatable, Sendable {
    public var routeId: String
    public var share: Double
    /// rides that matched (from this place, same day type, +-60 min, 60 days)
    public var n: Int

    public init(routeId: String, share: Double, n: Int) {
        self.routeId = routeId
        self.share = share
        self.n = n
    }
}

/// One ride of a week (Q22 / Q13-weekly)
public struct WeekRide: Equatable, Sendable {
    public var startAt: Int64
    public var utcOffsetMin: Int
    /// ride / shortHop
    public var kind: String
    public var distanceM: Double
    public var totalS: Double
    public var movingS: Double?
    public var usedPct: Double?
    public var timeAtMaxPct: Double?

    public init(startAt: Int64, utcOffsetMin: Int, kind: String, distanceM: Double, totalS: Double, movingS: Double? = nil,
                usedPct: Double? = nil, timeAtMaxPct: Double? = nil) {
        self.startAt = startAt
        self.utcOffsetMin = utcOffsetMin
        self.kind = kind
        self.distanceM = distanceM
        self.totalS = totalS
        self.movingS = movingS
        self.usedPct = usedPct
        self.timeAtMaxPct = timeAtMaxPct
    }

    /// The local day number (riding days, C22)
    public var localDay: Int64 { (startAt + Int64(utcOffsetMin) * 60_000) / OutsideTime.dayMs }
}

/// One ride's time at the speed cap on a route (Q13-after)
public struct CapRide: Equatable, Sendable {
    public var timeAtMaxPct: Double
    public var totalS: Double
    public var usedPct: Double?

    public init(timeAtMaxPct: Double, totalS: Double, usedPct: Double? = nil) {
        self.timeAtMaxPct = timeAtMaxPct
        self.totalS = totalS
        self.usedPct = usedPct
    }
}

public enum InsightWeek {
    /// Sunday 00:00 local of the week holding `ms` (epoch ms, UTC)
    public static func start(ms: Int64, utcOffsetMin: Int) -> Int64 {
        let off = Int64(utcOffsetMin) * 60_000
        let localDay = Int64((Double(ms + off) / Double(OutsideTime.dayMs)).rounded(.down))
        let weekday = Int64(DayClock.weekday(startAtMs: ms, utcOffsetMin: utcOffsetMin))
        return (localDay - weekday) * OutsideTime.dayMs - off
    }
}

// MARK: - The catalogue

public enum InsightCatalogue {
    // MARK: Q1-live: destination guess (T90)

    /// >= 4 rides from this place, same day type, start within +-60 min, last 60 days; the top destination >= 70%.
    public static func destinationGuess(rides: [DestinationRide], startPlaceId: String, nowMs: Int64, utcOffsetMin: Int) -> DestinationGuess? {
        let today = DayClock.dayType(weekday: DayClock.weekday(startAtMs: nowMs, utcOffsetMin: utcOffsetMin))
        let minute = DayClock.minuteOfDay(startAtMs: nowMs, utcOffsetMin: utcOffsetMin)
        let cutoff = nowMs - Int64(T.t90DestinationDays * Double(OutsideTime.dayMs))
        let matching = rides.filter { r in
            guard r.startPlaceId == startPlaceId, r.startAt >= cutoff, r.startAt <= nowMs else { return false }
            guard DayClock.dayType(weekday: DayClock.weekday(startAtMs: r.startAt, utcOffsetMin: r.utcOffsetMin)) == today else { return false }
            let m = DayClock.minuteOfDay(startAtMs: r.startAt, utcOffsetMin: r.utcOffsetMin)
            let d = abs(m - minute)
            return Double(min(d, 1440 - d)) <= T.t90DestinationWindowMin
        }
        guard matching.count >= T.t90DestinationRides else { return nil }
        var counts: [String: Int] = [:]
        for r in matching { counts[r.routeId, default: 0] += 1 }
        guard let top = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }
        let share = Double(top.value) / Double(matching.count)
        guard share >= T.t90DestinationShare else { return nil }
        return DestinationGuess(routeId: top.key, share: share, n: matching.count)
    }

    /// "Heading to Work? Fastest today: via park shortcut, about 14 min." (no variant comparison: "Heading to Work? About 14 min.")
    public static func q1Live(guess: DestinationGuess?, destination: String, variants: [InsightVariant], todayS: Double?,
                              rideId: String?, nowMs: Int64) -> [Insight] {
        guard let g = guess else { return [] }
        let compared = variants.filter(\.hasTimeGate)
        var text = "Heading to \(destination)?"
        var timeS = todayS
        if compared.count >= T.t91VariantCount, let fastest = compared.min(by: { ($0.medianTimeS ?? 0) < ($1.medianTimeS ?? 0) }) {
            timeS = todayS ?? fastest.medianTimeS
            text += " Fastest today: \(fastest.via)"
            if let t = timeS { text += ", about \(InsightText.minutes(t))" }
            text += "."
        } else if let t = timeS {
            text += " About \(InsightText.minutes(t))."
        }
        return [Insight(type: .q1Live, rideId: rideId, routeId: g.routeId, text: text, basedOnN: g.n, createdAt: nowMs)]
    }

    // MARK: Q1-after / Q2-after (T91, joined into one trade-off message)

    /// The ride did not take the fastest variant (>= 2 variants with >= 3 rides each): Q1 with Q2's battery part when both
    /// sides have >= 5 rides. The ride took the fastest but another uses >= 1 point less: Q2 alone. Below the gate: progress.
    public static func q1q2After(rideId: String, routeId: String, rideVariantId: String?, rideTimeS: Double?, variants: [InsightVariant],
                                 nowMs: Int64) -> [Insight] {
        guard variants.count >= T.t91VariantCount, let rv = variants.first(where: { $0.id == rideVariantId }) else { return [] }
        let gated = variants.filter(\.hasTimeGate)
        guard gated.count >= T.t91VariantCount, rv.hasTimeGate else {
            // pattern D: the variant with the fewest rides
            guard let short = variants.min(by: { $0.timesS.count < $1.timesS.count }) else { return [] }
            let text = "Comparing the ways: \(min(short.timesS.count, T.t91VariantRides)) of \(T.t91VariantRides) rides \(short.via)"
            return [Insight(type: .q1After, rideId: rideId, routeId: routeId, text: text,
                            basedOnN: variants.reduce(0) { $0 + $1.timesS.count }, isProgress: true, createdAt: nowMs)]
        }
        guard let fastest = gated.min(by: { ($0.medianTimeS ?? 0) < ($1.medianTimeS ?? 0) }),
              let ft = fastest.medianTimeS, let rt = rv.medianTimeS else { return [] }
        let n = rv.timesS.count + fastest.timesS.count
        if fastest.id != rv.id, rt - ft >= InsightRules.fasterByS, let fr = fastest.timeRange, let rr = rv.timeRange {
            var text = ""
            if let t = rideTimeS { text = "You took \(rv.via): \(InsightText.minutes(t)). " }
            text += InsightText.capitalised(fastest.via) + " is usually \(InsightText.minutes(rt - ft)) faster"
            var used: Double?
            if let fu = fastest.medianUsedPct, let ru = rv.medianUsedPct {
                let d = fu - ru
                if d >= InsightRules.lessBatteryByPct {
                    text += " but uses \(InsightText.pct(d)) more battery"
                    used = d
                } else if d <= -InsightRules.lessBatteryByPct {
                    text += " and uses less battery"
                    used = d
                }
            }
            text += " (\(InsightText.minuteRange(fr.lo, fr.hi)) vs \(InsightText.minuteRange(rr.lo, rr.hi)) · based on \(fastest.timesS.count) and \(rv.timesS.count) rides)."
            return [Insight(type: .q1After, rideId: rideId, routeId: routeId, text: text, basedOnN: n, timeS: rt - ft, usedPct: used, createdAt: nowMs)]
        }
        // Q2 alone: this ride was on the fastest (or as fast); another way uses clearly less battery
        guard let ru = rv.medianUsedPct else { return [] }
        let others = gated.filter { $0.id != rv.id && $0.medianUsedPct != nil }
        guard let eff = others.min(by: { ($0.medianUsedPct ?? 0) < ($1.medianUsedPct ?? 0) }), let eu = eff.medianUsedPct,
              ru - eu >= InsightRules.lessBatteryByPct, let et = eff.medianTimeS else { return [] }
        let slower = et - rt
        let timePart = slower >= InsightRules.fasterByS ? "is usually \(InsightText.minutes(slower)) slower" : "takes about the same time"
        let text = InsightText.capitalised(eff.via) + " uses about \(InsightText.pct(ru - eu)) less battery than \(rv.via) and \(timePart) "
            + "(based on \(eff.usedPct.count) and \(rv.usedPct.count) rides)."
        return [Insight(type: .q2After, rideId: rideId, routeId: routeId, text: text, basedOnN: eff.usedPct.count + rv.usedPct.count,
                        timeS: slower, usedPct: ru - eu, createdAt: nowMs)]
    }

    // MARK: Q2-live (T92): battery tight on arrival, a more efficient variant exists

    /// Decision with the margin: arrival % = battery - (planned use x 1.10) < 10%. The shown battery is the honest reading.
    public static func q2Live(batteryPct: Double, plannedVariantId: String?, variants: [InsightVariant], routeId: String, rideId: String?,
                              nowMs: Int64) -> [Insight] {
        let withBattery = variants.filter { $0.medianUsedPct != nil }
        guard withBattery.count >= T.t91VariantCount else { return [] }
        let planned = withBattery.first { $0.id == plannedVariantId } ?? withBattery.max { ($0.medianUsedPct ?? 0) < ($1.medianUsedPct ?? 0) }
        guard let p = planned, let pu = p.medianUsedPct,
              batteryPct - SafetyMargin.forDecision(pu) < T.t92TightArrivalPct,
              let eff = withBattery.min(by: { ($0.medianUsedPct ?? 0) < ($1.medianUsedPct ?? 0) }), eff.id != p.id,
              let eu = eff.medianUsedPct, eu < pu else { return [] }
        let text = "Battery \(Int(batteryPct.rounded()))%: take \(eff.via), it uses less."
        return [Insight(type: .q2Live, rideId: rideId, routeId: routeId, text: text, basedOnN: eff.usedPct.count + p.usedPct.count,
                        usedPct: pu - eu, createdAt: nowMs)]
    }

    // MARK: Q3-after / Q3-verdict (T93): only the stretch that differs

    /// `optionTimesS` = every ride's time through this option (this ride included, oldest first); `otherTimesS` = the rides
    /// through the other option(s) of the same choice point. Progress until both have 3 rides; the verdict once, at 3.
    public static func q3(rideId: String, routeId: String, optionId: String, optionName: String, rideOptionTimeS: Double,
                          optionTimesS: [Double], otherTimesS: [Double], nowMs: Int64) -> [Insight] {
        let need = T.t93ShortcutRides
        guard optionTimesS.count >= need, otherTimesS.count >= need, let other = Geo.median(otherTimesS) else {
            let have = min(optionTimesS.count, otherTimesS.count)
            let text = "\(InsightText.capitalised(optionName)): \(min(have, need)) of \(need) rides before a verdict"
            return [Insight(type: .q3After, rideId: rideId, routeId: routeId, subject: optionId, text: text,
                            basedOnN: optionTimesS.count + otherTimesS.count, isProgress: true, createdAt: nowMs)]
        }
        var out: [Insight] = []
        let savings = optionTimesS.map { other - $0 }
        let saved = other - rideOptionTimeS
        if let r = UsualRange.range(savings) {
            let usual: String
            if r.lo >= 0 {
                usual = "usually saves \(InsightText.duration(r.lo))–\(InsightText.duration(r.hi))"
            } else if r.hi <= 0 {
                usual = "usually costs \(InsightText.duration(r.hi))–\(InsightText.duration(r.lo))"
            } else {
                usual = "usually between \(InsightText.duration(r.hi)) faster and \(InsightText.duration(r.lo)) slower"
            }
            let head = saved >= 0 ? "The \(optionName) saved you \(InsightText.duration(saved)) on that stretch"
                : "The \(optionName) took \(InsightText.duration(saved)) longer on that stretch"
            out.append(Insight(type: .q3After, rideId: rideId, routeId: routeId, subject: optionId,
                               text: "\(head) (\(usual) · \(InsightText.basedOn(optionTimesS.count)))." , basedOnN: optionTimesS.count,
                               timeS: saved, createdAt: nowMs))
        }
        if optionTimesS.count == need, let m = Geo.median(savings) {
            let text: String
            if abs(m) < T.t93NoDifferenceS {
                text = "Verdict: no real difference with the \(optionName) (under \(Int(T.t93NoDifferenceS)) s)."
            } else if m > 0 {
                text = "Verdict: the \(optionName) saves about \(InsightText.minutes(m)) per ride. Worth it."
            } else {
                text = "Verdict: the \(optionName) costs about \(InsightText.minutes(m)) per ride."
            }
            out.append(Insight(type: .q3Verdict, rideId: rideId, routeId: routeId, subject: optionId, text: text,
                               basedOnN: optionTimesS.count + otherTimesS.count, timeS: m, createdAt: nowMs))
        }
        return out
    }

    // MARK: Q4-after (M14 + M24)

    /// The ride is noticeably different from the usual (M14; route >= 5 rides); the causes are the explanation's factors that
    /// passed M15, largest first; without any, the difference is said on its own.
    public static func q4After(rideId: String, routeId: String, rideTimeS: Double?, rideUsedPct: Double?, usualTime: UsualRangeValue?,
                               usualUsed: UsualRangeValue?, explanation: RideExplanation?, nowMs: Int64) -> [Insight] {
        var sentences: [String] = []
        var timeDiff: Double?, usedDiff: Double?
        var n = 0
        if let t = rideTimeS, let r = usualTime {
            switch UsualRange.noticeablyDifferent(value: t, range: r, minimumStep: UsualRange.minimumTimeStepS) {
            case .within: break
            case .above, .below:
                let d = t - r.median
                guard abs(d) >= 1 else { break }
                timeDiff = d
                n = max(n, r.n)
                let causes = (explanation?.items ?? [])
                    .filter { ($0.timeS ?? 0) * d > 0 && abs($0.timeS ?? 0) >= InsightRules.nameFactorS }
                    .sorted { abs($0.timeS ?? 0) > abs($1.timeS ?? 0) }
                    .map { "\(InsightText.factorLabel(factorId: $0.factorId, level: $0.level)) (~\(InsightText.duration($0.timeS ?? 0)))" }
                let head = "\(InsightText.minutes(d)) \(d > 0 ? "slower" : "faster") than usual"
                sentences.append(causes.isEmpty ? "\(head) (usually \(InsightText.minuteRange(r.lo, r.hi)) · \(InsightText.basedOn(r.n)))."
                                 : "\(head): \(causes.joined(separator: ", ")).")
            }
        }
        if let u = rideUsedPct, let r = usualUsed {
            switch UsualRange.noticeablyDifferent(value: u, range: r, minimumStep: UsualRange.minimumBatteryStepPct) {
            case .within: break
            case .above, .below:
                let d = u - r.median
                guard abs(d) >= 0.5 else { break }
                usedDiff = d
                n = max(n, r.n)
                let causes = (explanation?.items ?? [])
                    .filter { ($0.usedPct ?? 0) * d > 0 && abs($0.usedPct ?? 0) >= InsightRules.nameFactorPct }
                    .sorted { abs($0.usedPct ?? 0) > abs($1.usedPct ?? 0) }
                    .map { "\(InsightText.factorLabel(factorId: $0.factorId, level: $0.level)) (\(InsightText.signedPct($0.usedPct ?? 0)))" }
                let head = "\(InsightText.pct(d)) \(d > 0 ? "more" : "less") battery than usual"
                sentences.append(causes.isEmpty ? "\(InsightText.capitalised(head)) (usually \(InsightText.pct(r.lo))–\(InsightText.pct(r.hi)) · \(InsightText.basedOn(r.n)))."
                                 : "\(InsightText.capitalised(head)): \(causes.joined(separator: ", ")).")
            }
        }
        guard !sentences.isEmpty else { return [] }
        return [Insight(type: .q4After, rideId: rideId, routeId: routeId, text: sentences.joined(separator: " "), basedOnN: n,
                        timeS: timeDiff, usedPct: usedDiff, createdAt: nowMs)]
    }

    // MARK: Q4-weekly

    /// The factor that cost most this week (sum of the rides' explained costs, all passed M15)
    public static func q4Weekly(weekStart: Int64, explanations: [RideExplanation], nowMs: Int64) -> [Insight] {
        var time: [String: Double] = [:], used: [String: Double] = [:], rides: [String: Int] = [:]
        for e in explanations {
            for i in e.items {
                let label = InsightText.factorLabel(factorId: i.factorId, level: i.level)
                if let t = i.timeS, t > 0 { time[label, default: 0] += t }
                if let u = i.usedPct, u > 0 { used[label, default: 0] += u }
                rides[label, default: 0] += 1
            }
        }
        let size: (String) -> Double = { 5 * (time[$0] ?? 0) / 60 + 3 * (used[$0] ?? 0) }
        guard let top = Set(time.keys).union(used.keys).max(by: { size($0) != size($1) ? size($0) < size($1) : $0 > $1 }) else { return [] }
        let t = time[top] ?? 0, u = used[top] ?? 0
        guard t >= InsightRules.weeklyMinS || u >= InsightRules.weeklyMinPct else { return [] }
        var parts: [String] = []
        if t >= InsightRules.weeklyMinS { parts.append("~\(InsightText.minutes(t))") }
        if u >= InsightRules.weeklyMinPct { parts.append("~\(InsightText.pct(u)) battery") }
        let text = "Biggest factor this week: \(top), which cost you \(parts.joined(separator: " and ")) in total (\(InsightText.basedOn(rides[top] ?? 0)))."
        return [Insight(type: .q4Weekly, weekStart: weekStart, subject: "w\(weekStart)", text: text, basedOnN: rides[top] ?? 0,
                        timeS: t, usedPct: u, createdAt: nowMs)]
    }

    // MARK: Q9-live (M2-09, wrapped)

    /// The M2-09 ride-start warning as an insight row (the text is `ThereAndBack.startWarning`, the decision used `neededPct`,
    /// i.e. the 10% margin). nil-equivalent (empty) when the trip fits.
    public static func q9Live(model: ThereAndBackModel?, routeId: String, rideId: String?, basedOnN: Int, nowMs: Int64) -> [Insight] {
        guard let m = model, let text = ThereAndBack.startWarning(m) else { return [] }
        return [Insight(type: .q9Live, rideId: rideId, routeId: routeId, text: text, basedOnN: basedOnN, createdAt: nowMs)]
    }

    // MARK: Q13-after / Q13-weekly (T96; needs time at max, M20)

    public static func q13After(rideId: String, routeId: String, routeName: String?, rides: [CapRide], nowMs: Int64) -> [Insight] {
        guard !rides.isEmpty else { return [] }      // no time-at-max data yet (D7 point 3): nothing at all
        let flat = rides.filter { $0.timeAtMaxPct >= InsightRules.flatOutShare }
        let calm = rides.filter { $0.timeAtMaxPct <= InsightRules.calmShare }
        let need = T.t67EnoughTimeRides
        let route = InsightText.route(routeName)
        guard rides.count >= InsightRules.q13RouteRides, flat.count >= need, calm.count >= need,
              let ft = Geo.median(flat.map(\.totalS)), let ct = Geo.median(calm.map(\.totalS)) else {
            let text = rides.count < InsightRules.q13RouteRides
                ? "Speed cap on \(route): \(rides.count) of \(InsightRules.q13RouteRides) rides"
                : "Speed cap on \(route): \(min(flat.count, need)) of \(need) flat-out rides, \(min(calm.count, need)) of \(need) calmer rides"
            return [Insight(type: .q13After, rideId: rideId, routeId: routeId, text: text, basedOnN: rides.count, isProgress: true, createdAt: nowMs)]
        }
        let saved = ct - ft
        var cost: Double?
        let fu = flat.compactMap(\.usedPct), cu = calm.compactMap(\.usedPct)
        if fu.count >= T.t67EnoughBatteryRides, cu.count >= T.t67EnoughBatteryRides, let a = Geo.median(fu), let b = Geo.median(cu) { cost = a - b }
        guard saved >= T.t96NoteworthyS || (cost ?? 0) >= T.t96NoteworthyPct else { return [] }
        var text = "\(route): riding flat out saves you ~\(InsightText.minutes(max(0, saved)))"
        if let c = cost { text += c >= 0 ? " but costs ~\(InsightText.pct(c)) battery" : " and uses ~\(InsightText.pct(c)) less battery" }
        text += " compared to your calmer rides (\(InsightText.basedOn(flat.count + calm.count)))."
        return [Insight(type: .q13After, rideId: rideId, routeId: routeId, text: text, basedOnN: flat.count + calm.count,
                        timeS: saved, usedPct: cost, createdAt: nowMs)]
    }

    /// >= 3 rides with time at max this week. `savedS` / `costPct` (the route comparisons' totals) are added when known.
    public static func q13Weekly(weekStart: Int64, rides: [WeekRide], capKmh: Int?, savedS: Double?, costPct: Double?, nowMs: Int64) -> [Insight] {
        let with = rides.filter { $0.timeAtMaxPct != nil && ($0.movingS ?? $0.totalS) > 0 }
        guard with.count >= 3 else { return [] }
        let moving = with.reduce(0.0) { $0 + ($1.movingS ?? $1.totalS) }
        let atMax = with.reduce(0.0) { $0 + ($1.movingS ?? $1.totalS) * ($1.timeAtMaxPct ?? 0) / 100 }
        let share = moving > 0 ? atMax / moving * 100 : 0
        var text = "You rode at the speed cap\(capKmh.map { " (\($0) km/h)" } ?? "") \(Int(share.rounded()))% of the time this week."
        if let s = savedS, s >= 60, let c = costPct, c > 0 {
            text += " That saved ~\(InsightText.minutes(s)) and cost ~\(InsightText.pct(c)) battery, about \(InsightText.duration(s / c)) per 1% of battery."
        } else if let s = savedS, s >= 60 {
            text += " That saved ~\(InsightText.minutes(s))."
        }
        return [Insight(type: .q13Weekly, weekStart: weekStart, subject: "w\(weekStart)", text: text, basedOnN: with.count,
                        timeS: savedS, usedPct: costPct, createdAt: nowMs)]
    }

    // MARK: Q15-live / Q15-after / Q15-notify (T94)

    /// Wind along the route > 15 km/h (forecast headwind component, `RideWeatherCalc.headwind` on the variant path) and the
    /// route's W1 effect for that side passes M15. Live has no progress line (the ride-start budget is 2 messages).
    public static func q15Live(routeId: String, routeName: String?, forecastHeadwindKmh: Double?, routeEffects: [FactorEffect], rideId: String?,
                               nowMs: Int64) -> [Insight] {
        guard let hw = forecastHeadwindKmh, abs(hw) > T.t94HeadwindKmh else { return [] }
        let level = hw > 0 ? "head" : "tail"
        let time = routeEffects.first { $0.factorId == "W1" && $0.level == level && $0.quantity == .time && $0.passesGate }
        let used = routeEffects.first { $0.factorId == "W1" && $0.level == level && $0.quantity == .used && $0.passesGate }
        guard let t = time?.effect else { return [] }
        let route = InsightText.route(routeName)
        var text: String
        if hw > 0 {
            text = "Headwind today on \(route): expect \(InsightText.signedDuration(t))"
            if let u = used?.effect { text += ", \(InsightText.signedPct(u)) battery" }
        } else {
            text = "Tailwind today on \(route): expect about \(InsightText.duration(t)) \(t < 0 ? "faster" : "slower")"
            if let u = used?.effect { text += ", \(InsightText.pct(u)) \(u < 0 ? "less" : "more") battery" }
        }
        let n = time?.n ?? 0
        text += " (based on \(n) \(InsightText.withNoun(factorId: "W1", level: level)))."
        return [Insight(type: .q15Live, rideId: rideId, routeId: routeId, text: text, basedOnN: n, timeS: t, usedPct: used?.effect, createdAt: nowMs)]
    }

    /// Credit both ways when the ride's explained wind effect is >= 1 min or >= 1%; a windy ride whose route effect is still
    /// under its gate gets the progress line.
    public static func q15After(rideId: String, routeId: String?, routeName: String?, rideHeadwindKmh: Double?, explanation: RideExplanation?,
                                routeEffects: [FactorEffect], nowMs: Int64) -> [Insight] {
        let items = (explanation?.items ?? []).filter { $0.factorId == "W1" }
        let t = items.compactMap(\.timeS).reduce(0, +)
        let u = items.compactMap(\.usedPct).reduce(0, +)
        if !items.isEmpty, abs(t) >= T.t96NoteworthyS || abs(u) >= 1 {
            let tail = items.first?.level == "tail" || (t < 0 && u <= 0)
            var parts: [String] = []
            if abs(t) >= InsightRules.nameFactorS { parts.append("~\(InsightText.minutes(t))") }
            if abs(u) >= InsightRules.nameFactorPct { parts.append("~\(InsightText.pct(u)) battery") }
            let verb: String
            if tail { verb = (t <= 0 && u <= 0) ? "saved you" : "changed your ride by" } else { verb = (t >= 0 && u >= 0) ? "cost you" : "changed your ride by" }
            let text = "\(tail ? "Tailwind" : "Headwind") \(verb) \(parts.joined(separator: " and ")) today."
            let n = routeEffects.first { $0.factorId == "W1" && $0.passesGate }?.n ?? 0
            return [Insight(type: .q15After, rideId: rideId, routeId: routeId, text: text, basedOnN: n, timeS: t, usedPct: u, createdAt: nowMs)]
        }
        // progress: a windy ride, the route's wind effect not there yet
        guard let hw = rideHeadwindKmh, abs(hw) >= FactorRules.headwindLevelKmh, routeId != nil else { return [] }
        let level = hw > 0 ? "head" : "tail"
        guard let e = routeEffects.first(where: { $0.factorId == "W1" && $0.level == level && $0.quantity == .time }),
              !e.passesGate, let line = InsightText.progress(e) else { return [] }
        let text = "\(InsightText.capitalised(InsightText.factorLabel(factorId: "W1", level: level))) on \(InsightText.route(routeName)): \(line)"
        return [Insight(type: .q15After, rideId: rideId, routeId: routeId, text: text, basedOnN: e.basedOnN, isProgress: true, createdAt: nowMs)]
    }

    /// 9.4 "wind picking up": a usual ride likely within 3 h (`likelyRideSoon`), forecast headwind along that route >= moderate
    /// (15 km/h) or up >= 10 km/h since the last forecast, and the pooled W1 head effect passes. Range in km, time per km plus
    /// the route total. Once a day (dedupe per day).
    public static func q15Notify(routeId: String, routeName: String?, routeKm: Double, likelyRideSoon: Bool, forecastHeadwindKmh: Double,
                                 previousForecastKmh: Double?, pooledEffects: [FactorEffect], rangeKm: Double?, usualPctPerKm: Double?,
                                 nowMs: Int64) -> [Insight] {
        guard likelyRideSoon, forecastHeadwindKmh > 0 else { return [] }
        let rose = previousForecastKmh.map { forecastHeadwindKmh - $0 >= InsightRules.windRoseKmh } ?? false
        guard forecastHeadwindKmh >= T.t70WindLightKmh || rose else { return [] }
        guard let sPerKm = pooledEffects.first(where: { $0.factorId == "W1" && $0.level == "head" && $0.quantity == .time && $0.passesGate })?.effect,
              sPerKm > 0 else { return [] }
        let pctPerKm = pooledEffects.first { $0.factorId == "W1" && $0.level == "head" && $0.quantity == .used && $0.passesGate }?.effect
        var text = "Wind is picking up today: this should"
        if let extra = pctPerKm, extra > 0, let r = rangeKm, let base = usualPctPerKm, base > 0 {
            let cut = r - r * base / (base + extra)
            if cut >= 0.5 { text += " cut your range by ~\(Int(cut.rounded())) km and" }
        }
        text += " add ~\(Int(sPerKm.rounded())) s per km to your ride (\(InsightText.route(routeName)): \(InsightText.signedDuration(sPerKm * routeKm)))."
        let n = pooledEffects.first { $0.factorId == "W1" && $0.level == "head" && $0.quantity == .time }?.n ?? 0
        return [Insight(type: .q15Notify, routeId: routeId, subject: routeId, text: text, basedOnN: n, timeS: sPerKm * routeKm,
                        usedPct: pctPerKm.map { $0 * routeKm }, createdAt: nowMs)]
    }

    // MARK: Q17-new: first time a climb is seen on a route

    public static func q17New(rideId: String, routeId: String?, climbId: String, climbName: String?, gainM: Double, nowMs: Int64) -> [Insight] {
        let name = climbName.map { "\($0) " } ?? ""
        let text = "New climb detected: \(name)(+\(Int(gainM.rounded())) m). We'll track what it costs you."
        return [Insight(type: .q17New, rideId: rideId, routeId: routeId, subject: climbId, text: text, basedOnN: 1, createdAt: nowMs)]
    }

    // MARK: Q18: is the flatter variant worth the extra distance?

    /// Two variants with >= 3 rides each differ by >= 8 m of climbing and the flatter one is longer.
    public static func q18(rideId: String, routeId: String, variants: [InsightVariant], nowMs: Int64) -> [Insight] {
        let gated = variants.filter { $0.hasTimeGate && Geo.median($0.gainM) != nil && Geo.median($0.distanceM) != nil }
        guard gated.count >= 2 else { return [] }
        var best: (flat: InsightVariant, steep: InsightVariant, dg: Double)?
        for a in gated {
            for b in gated where a.id != b.id {
                let dg = (Geo.median(b.gainM) ?? 0) - (Geo.median(a.gainM) ?? 0)
                let dd = (Geo.median(a.distanceM) ?? 0) - (Geo.median(b.distanceM) ?? 0)
                if dg >= InsightRules.flatterByM, dd > 0, dg > (best?.dg ?? 0) { best = (flat: a, steep: b, dg: dg) }
            }
        }
        guard let pair = best else { return [] }
        let dd = (Geo.median(pair.flat.distanceM) ?? 0) - (Geo.median(pair.steep.distanceM) ?? 0)
        let dt = (pair.flat.medianTimeS ?? 0) - (pair.steep.medianTimeS ?? 0)
        var text = "\(InsightText.capitalised(pair.flat.via)) (flatter): +\(InsightText.km(dd)), \(Int(pair.dg.rounded())) m less climbing"
        var parts: [String] = []
        var du: Double?
        if let fu = pair.flat.medianUsedPct, let su = pair.steep.medianUsedPct {
            du = fu - su
            parts.append("\(InsightText.signedPct(fu - su)) battery")
        }
        parts.append(InsightText.signedDuration(dt))
        text += " → " + parts.joined(separator: ", ") + "."
        if let d = du, d < 0 { text += " Worth it when battery is low." }
        let n = pair.flat.timesS.count + pair.steep.timesS.count
        return [Insight(type: .q18, rideId: rideId, routeId: routeId, text: text, basedOnN: n, timeS: dt, usedPct: du, createdAt: nowMs)]
    }

    // MARK: Q19-after: a loaded ride on a saved route (L1 pooled, per km per kg)

    public static func q19After(rideId: String, routeId: String, loadKg: Double?, loadLevel: String?, rideKm: Double, pooledEffects: [FactorEffect],
                                nowMs: Int64) -> [Insight] {
        guard let kg = loadKg, kg > 0 else { return [] }
        let l1 = pooledEffects.filter { $0.factorId == "L1" }
        let time = l1.first { $0.quantity == .time && $0.passesGate }
        let used = l1.first { $0.quantity == .used && $0.passesGate }
        let name = loadLevel.map { InsightText.capitalised($0) } ?? "\(Int(kg.rounded())) kg"
        guard time != nil || used != nil else {
            guard let e = l1.first(where: { $0.quantity == .used }) ?? l1.first, let line = InsightText.progress(e) else { return [] }
            return [Insight(type: .q19After, rideId: rideId, routeId: routeId, text: "Load: \(line)", basedOnN: e.basedOnN, isProgress: true, createdAt: nowMs)]
        }
        let t = time?.effect.map { $0 * kg * rideKm }
        let u = used?.effect.map { $0 * kg * rideKm }
        var parts: [String] = []
        if let u { parts.append("\(InsightText.signedPct(u)) battery") }
        if let t, abs(t) >= 1 { parts.append(InsightText.signedDuration(t)) }
        let n = (used ?? time)?.n ?? 0
        var text = "With a load (\(name)): \(parts.joined(separator: ", ")) compared to usual (based on \(n) loaded \(n == 1 ? "ride" : "rides"))."
        if used?.uncertain == true || time?.uncertain == true { text += " Uncertain so far." }
        return [Insight(type: .q19After, rideId: rideId, routeId: routeId, text: text, basedOnN: n, timeS: t, usedPct: u, createdAt: nowMs)]
    }

    // MARK: Q22-weekly (C22: >= 2 riding days)

    /// `label` "Last week" for the finished week (the Sunday notification), "This week so far" for the running one.
    public static func q22Weekly(weekStart: Int64, rides: [WeekRide], previousWeekKm: Double?, label: String = "Last week", nowMs: Int64) -> [Insight] {
        let days = Set(rides.map(\.localDay))
        guard days.count >= 2 else { return [] }
        let real = rides.filter { $0.kind == "ride" }
        let hops = rides.filter { $0.kind == "shortHop" }
        let km = real.reduce(0.0) { $0 + $1.distanceM } / 1000
        let seconds = real.reduce(0.0) { $0 + $1.totalS }
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        var parts = ["\(label): \(Int(km.rounded())) km", "\(real.count) \(real.count == 1 ? "ride" : "rides")",
                     h > 0 ? "\(h) h \(m) min" : "\(m) min"]
        if !hops.isEmpty {
            let hk = hops.reduce(0.0) { $0 + $1.distanceM } / 1000
            parts.append("+\(hops.count) short \(hops.count == 1 ? "hop" : "hops") (\(String(format: "%.1f", hk)) km)")
        }
        let used = rides.compactMap(\.usedPct).reduce(0, +)
        if used > 0 { parts.append("Battery used: ~\(String(format: "%.1f", used / 100)) full charges") }
        if let prev = previousWeekKm, prev > 0 {
            let total = (real + hops).reduce(0.0) { $0 + $1.distanceM } / 1000
            let change = (total - prev) / prev * 100
            if abs(change) >= 1 { parts.append(change > 0 ? "▲ \(Int(change.rounded()))% more than the week before" : "▼ \(Int((-change).rounded()))% less than the week before") }
        }
        return [Insight(type: .q22Weekly, weekStart: weekStart, subject: "w\(weekStart)", text: parts.joined(separator: " · "),
                        basedOnN: rides.count, createdAt: nowMs)]
    }

    // MARK: First / unlock (STATES step 4 S2: one quiet after-ride card each)

    /// `realRides` = real rides so far (this one included); `routeRides` = this route's rides (this one included);
    /// `calibratedNow` = the calibration became calibrated with this ride; `firstRangeKm` = the battery page's first range.
    public static func firstAndUnlock(rideId: String, realRides: Int, routeId: String?, routeName: String?, routeRides: Int, routeBatteryRides: Int,
                                      calibratedNow: Bool, whPerPct: Double?, firstRangeKm: Double?, nowMs: Int64) -> [Insight] {
        var out: [Insight] = []
        if realRides == 1 {
            out.append(Insight(type: .firstRide, rideId: rideId, subject: "first", text: "Your first ride is in · Ride the same trip 3 times and you'll see how it compares",
                               basedOnN: 1, createdAt: nowMs))
        }
        if let routeId {
            let route = InsightText.route(routeName)
            if routeRides == T.t67EnoughTimeRides {
                out.append(Insight(type: .unlockTime, rideId: rideId, routeId: routeId,
                                   text: "\(route): 3 rides, so time ranges, a Today estimate and the arrival time are on.", basedOnN: routeRides, createdAt: nowMs))
            }
            if routeBatteryRides == T.t67EnoughBatteryRides {
                out.append(Insight(type: .unlockBattery, rideId: rideId, routeId: routeId,
                                   text: "\(route): 5 rides, so battery ranges and the there-and-back check are on.", basedOnN: routeBatteryRides, createdAt: nowMs))
            }
        }
        if calibratedNow {
            var text = "Battery calibrated from your last \(T.t41CalibrationRides) rides"
            if let w = whPerPct { text += ": about \(String(format: "%.1f", w)) Wh per 1%" }
            out.append(Insight(type: .unlockCalibration, rideId: rideId, subject: "calibration", text: text + ".", basedOnN: T.t41CalibrationRides, createdAt: nowMs))
        }
        if let r = firstRangeKm {
            out.append(Insight(type: .unlockRange, rideId: rideId, subject: "range",
                               text: "Real range is on: about \(Int(r.rounded())) km at the current battery (Battery page).", basedOnN: realRides, createdAt: nowMs))
        }
        return out
    }
}
