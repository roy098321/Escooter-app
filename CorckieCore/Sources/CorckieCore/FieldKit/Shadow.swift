import Foundation

// T-00 part 2 (P6_PLAN section 2, point 2): shadow thresholds. For the rules that are still guesses the app also works out
// what the *other* values would have decided for every ride, and stores it. No behaviour changes: the standard value
// decides, the others only get logged. The weekly report then shows where a different value would have decided
// differently, and tuning needs no re-riding.
//
// Everything here is computed from what a closed ride stored (the 5-s samples), so it is approximate by the 5-s step.

/// One stored sample, reduced to what the shadow rules need.
public struct ShadowSample: Equatable, Sendable {
    /// Seconds from the ride start
    public var t: Double
    /// The scooter link was live (`mode == scooter`)
    public var scooter: Bool
    /// Scooter speed, km/h
    public var scooterKmh: Double?
    /// Phone GPS speed, km/h
    public var gpsKmh: Double?

    public init(t: Double, scooter: Bool, scooterKmh: Double?, gpsKmh: Double?) {
        self.t = t
        self.scooter = scooter
        self.scooterKmh = scooterKmh
        self.gpsKmh = gpsKmh
    }

    /// The speed the screen shows: the scooter's while linked, else the GPS's
    public var shownKmh: Double? { scooter ? (scooterKmh ?? gpsKmh) : (gpsKmh ?? scooterKmh) }
}

public struct ShadowDecision: Equatable, Sendable {
    public var rule: String
    public var variant: String
    public var decision: String
    /// This variant decided differently from the standard one for this ride
    public var differs: Bool
    public var isStandard: Bool
}

/// A stored decision, for the report.
public struct ShadowRow: Equatable, Sendable {
    public var startAt: Int64
    public var rule: String
    public var variant: String
    public var decision: String
    public var differs: Bool
    public var isStandard: Bool

    public init(startAt: Int64, rule: String, variant: String, decision: String, differs: Bool, isStandard: Bool) {
        self.startAt = startAt
        self.rule = rule
        self.variant = variant
        self.decision = decision
        self.differs = differs
        self.isStandard = isStandard
    }
}

public enum ShadowCalc {
    public static let stepS = RideCheckRules.sampleStepS

    /// Rule names (stored)
    public static let ruleEnd = "end"
    public static let ruleStart = "autostart"
    public static let ruleSlow = "slow"
    public static let ruleDifferent = "different"
    public static let ruleGateTime = "gate.time"
    public static let ruleGateBattery = "gate.battery"
    public static let ruleGateRoute = "gate.route"

    static let titles: [String: String] = [
        ruleEnd: "Ride end after standing still (30 / 60 / 90 s)",
        ruleStart: "Autostart speed (2 / 3 / 4 km/h)",
        ruleSlow: "SLOW warning (45 / 48 km/h)",
        ruleDifferent: "Noticeably different (60 s or 2% / 45 s or 1.5% / 90 s or 3%)",
        ruleGateTime: "Time estimate gate (rides needed: 3, shadow 2 / 4)",
        ruleGateBattery: "Battery estimate gate (rides needed: 5, shadow 4 / 6)",
        ruleGateRoute: "Route suggestion gate (trips needed: 2, shadow 1 / 3)"
    ]

    /// Everything for one closed ride. `routeRides` are the ride's other rides on its route (nil = not on a route).
    public static func evaluate(samples: [ShadowSample], thisTotalS: Double?, thisUsedPct: Double?, route: RouteHistory?) -> [ShadowDecision] {
        var out = end(samples) + autostart(samples) + slow(samples)
        if let r = route {
            out += different(thisTotalS: thisTotalS, thisUsedPct: thisUsedPct, otherTotalS: r.otherTotalS, otherUsedPct: r.otherUsedPct)
            out += gates(timedRides: r.otherTotalS.count + (thisTotalS == nil ? 0 : 1),
                         batteryRides: r.otherUsedPct.count + (thisUsedPct == nil ? 0 : 1), trips: r.otherTotalS.count + 1)
        }
        return out
    }

    public struct RouteHistory: Equatable, Sendable {
        public var otherTotalS: [Double]
        public var otherUsedPct: [Double]

        public init(otherTotalS: [Double], otherUsedPct: [Double]) {
            self.otherTotalS = otherTotalS
            self.otherUsedPct = otherUsedPct
        }
    }

    // MARK: Ride end (T17 / T20): how long the ride stood still at its end

    /// Variants end the ride 30 / 60 / 90 s after the last movement. The standard (30) closed the stored ride; a longer wait would
    /// have kept it open until the stillness reached that length.
    public static func end(_ samples: [ShadowSample]) -> [ShadowDecision] {
        guard let last = samples.last else { return [] }
        let lastMove = samples.last { ($0.shownKmh ?? 0) >= T.t102PushingMinKmh }
        let still = max(0, last.t - (lastMove?.t ?? 0))
        let variants: [Double] = [T.t17EndDisconnectedS, 60, 90]
        func decide(_ x: Double) -> String {
            still >= x ? "ends \(Int(x)) s after the last movement" : "still open (stood still only \(Int(still)) s)"
        }
        let standard = decide(variants[0])
        return variants.enumerated().map { i, x in
            let d = decide(x)
            return ShadowDecision(rule: ruleEnd, variant: "\(Int(x)) s", decision: d, differs: d != standard, isStandard: i == 0)
        }
    }

    // MARK: Autostart (T10)

    /// When the scooter speed first passed 2 (standard) / 3 / 4 km/h, seconds after the ride start.
    public static func autostart(_ samples: [ShadowSample]) -> [ShadowDecision] {
        let variants: [Double] = [T.t10AutostartKmh, 3, 4]
        func first(_ x: Double) -> Double? { samples.first { $0.scooter && ($0.scooterKmh ?? 0) > x }?.t }
        func text(_ t: Double?) -> String { t.map { "first above the limit at +\(Int($0)) s" } ?? "never above the limit" }
        let std = first(variants[0])
        return variants.enumerated().map { i, x in
            let t = first(x)
            let same = (t == nil && std == nil) || (t != nil && std != nil && abs(t! - std!) < stepS)
            return ShadowDecision(rule: ruleStart, variant: "\(Int(x)) km/h", decision: text(t), differs: !same, isStandard: i == 0)
        }
    }

    // MARK: SLOW (T99)

    /// How many times the warning would have come on at 45 (standard) and at 48 km/h.
    public static func slow(_ samples: [ShadowSample]) -> [ShadowDecision] {
        func count(_ on: Double, _ clear: Double) -> Int {
            var w = SpeedWarning(onAboveKmh: on, clearBelowKmh: clear)
            var n = 0
            var was = false
            for s in samples {
                guard let v = s.shownKmh else { continue }
                let now = w.update(speedKmh: v)
                if now && !was { n += 1 }
                was = now
            }
            return n
        }
        let std = count(T.t99SlowKmh, T.t99ClearKmh)
        let alt = count(48, 46)
        func text(_ n: Int) -> String { n == 1 ? "1 warning" : "\(n) warnings" }
        return [ShadowDecision(rule: ruleSlow, variant: "45 km/h", decision: text(std), differs: false, isStandard: true),
                ShadowDecision(rule: ruleSlow, variant: "48 km/h", decision: text(alt), differs: alt != std, isStandard: false)]
    }

    // MARK: Noticeably different (T66)

    /// This ride against the route's median of its other rides (needs 3 timed ones, like the Today estimate).
    public static func different(thisTotalS: Double?, thisUsedPct: Double?, otherTotalS: [Double], otherUsedPct: [Double]) -> [ShadowDecision] {
        guard let t = thisTotalS, otherTotalS.count >= T.t67EnoughTimeRides, let medT = Geo.median(otherTotalS) else { return [] }
        let dT = abs(t - medT)
        var dP: Double?
        if let u = thisUsedPct, otherUsedPct.count >= T.t67EnoughBatteryRides, let m = Geo.median(otherUsedPct) { dP = abs(u - m) }
        let variants: [(name: String, s: Double, p: Double)] = [("60 s or 2%", T.t66DifferentS, T.t66DifferentPct), ("45 s or 1.5%", 45, 1.5), ("90 s or 3%", 90, 3)]
        func decide(_ s: Double, _ p: Double) -> String { (dT >= s || (dP ?? 0) >= p) ? "noticeably different" : "usual" }
        let std = decide(variants[0].s, variants[0].p)
        return variants.enumerated().map { i, v in
            let d = decide(v.s, v.p)
            return ShadowDecision(rule: ruleDifferent, variant: v.name, decision: d, differs: d != std, isStandard: i == 0)
        }
    }

    // MARK: Insight gates (T63, T67)

    public static func gates(timedRides: Int, batteryRides: Int, trips: Int) -> [ShadowDecision] {
        func gate(_ rule: String, have: Int, need: Int) -> [ShadowDecision] {
            func decide(_ n: Int) -> String { have >= n ? "open (\(have) rides so far)" : "closed (\(have) rides so far)" }
            let std = decide(need)
            return [need, need - 1, need + 1].enumerated().map { i, n in
                let d = decide(n)
                return ShadowDecision(rule: rule, variant: "\(n) rides", decision: d, differs: d != std, isStandard: i == 0)
            }
        }
        return gate(ruleGateTime, have: timedRides, need: T.t67EnoughTimeRides)
            + gate(ruleGateBattery, have: batteryRides, need: T.t67EnoughBatteryRides)
            + gate(ruleGateRoute, have: trips, need: T.t63SuggestRouteTrips)
    }

    // MARK: Report

    /// shadow.txt: per rule and variant, in how many rides it would have decided differently, plus the newest differing rides.
    public static func text(_ rows: [ShadowRow], now: String) -> String {
        var out = "Shadow thresholds \u{00B7} \(now)\n"
        out += "What other values would have decided for each ride. The standard value decided; nothing here changed behaviour.\n"
        out += "Worked out from the stored 5-second samples, so times are approximate by 5 s.\n"
        let rules = [ruleEnd, ruleStart, ruleSlow, ruleDifferent, ruleGateTime, ruleGateBattery, ruleGateRoute]
        for rule in rules {
            let ofRule = rows.filter { $0.rule == rule }
            out += "\n\(titles[rule] ?? rule)\n"
            guard !ofRule.isEmpty else { out += "  no rides yet\n"; continue }
            for variant in orderedVariants(ofRule) {
                let v = ofRule.filter { $0.variant == variant }
                let std = v.contains { $0.isStandard }
                let diff = v.filter(\.differs).count
                out += "  \(variant)\(std ? " (standard)" : ""): \(v.count) rides"
                out += std ? "\n" : ", decided differently in \(diff)\n"
            }
            let newest = ofRule.filter { $0.differs }.sorted { $0.startAt > $1.startAt }.prefix(5)
            for r in newest {
                let date = Date(timeIntervalSince1970: Double(r.startAt) / 1000).formatted(date: .abbreviated, time: .shortened)
                out += "    \(date) \u{00B7} \(r.variant): \(r.decision)\n"
            }
        }
        return out
    }

    static func orderedVariants(_ rows: [ShadowRow]) -> [String] {
        var seen: [String] = []
        for r in rows.sorted(by: { ($0.isStandard ? 0 : 1, $0.variant) < ($1.isStandard ? 0 : 1, $1.variant) }) where !seen.contains(r.variant) {
            seen.append(r.variant)
        }
        return seen
    }
}
