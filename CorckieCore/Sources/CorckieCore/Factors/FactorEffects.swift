import Foundation

// M4-02: what each factor costs (CALC_SPEC M24, gates M15), per route (per trip) and pooled (per km, all routes).
// Main = matched comparison: rides with vs without the factor, stratified by the 2 strongest other factors (from the
// regression), effect = weighted mean of the per-stratum median differences. Confirmation = ridge regression of the
// per-km quantity on all factors; an effect is shown only when the regression agrees on sign and is within x2 (T76).
// Gate: >= 3 rides with and without for time, >= 5 for battery (T67), larger than the MAD of the quantity, confirmed;
// rain and hills only pooled (rare factors / route properties), load only pooled per kg (M23).
// Nothing is shown before its gate: a result that does not pass carries no effect value, only its counts (pattern D).

public enum FactorQuantity: String, CaseIterable, Sendable {
    /// trip time, seconds (`totalS`)
    case time
    /// battery used, percentage points (`usedPct`)
    case used

    /// T67: time 3 rides, battery 5, with and without
    public var needed: Int { self == .time ? T.t67EnoughTimeRides : T.t67EnoughBatteryRides }
}

public enum FactorScope: String, Sendable {
    /// per trip on one route
    case route
    /// per km, all routes, last 12 months
    case pooled
}

public enum FactorGate: String, Sendable {
    case passed
    /// fewer than `needed` rides with or without the factor
    case notEnoughRides
    /// the effect is not larger than the MAD of the quantity
    case withinNoise
    /// the regression disagrees on sign or by more than x2 (or cannot tell)
    case notConfirmed
    /// the factor almost always comes with another one: see the combined row
    case combined

    /// Stored in `factor_effect.confidence` for a row that did not pass (a passed row stores its confidence, > 0)
    public var code: Double {
        switch self {
        case .passed: return 1
        case .notEnoughRides: return -1
        case .withinNoise: return -2
        case .notConfirmed: return -3
        case .combined: return -4
        }
    }

    public static func from(confidence: Double?) -> FactorGate {
        guard let c = confidence else { return .notEnoughRides }
        if c > 0 { return .passed }
        switch c {
        case -2: return .withinNoise
        case -3: return .notConfirmed
        case -4: return .combined
        default: return .notEnoughRides
        }
    }
}

/// One factor effect (a `factor_effect` row; hand-off to M4-03 insights and the M4-08 Factors page).
public struct FactorEffect: Equatable, Sendable {
    /// W1 W3 R1 T1 T2 L1, or two joined by "+" for a combined factor ("W1+W3")
    public var factorId: String
    /// head / tail / wet / hilly / rush / friday / saturday / perKg / perKgUncertain; "head+wet" for a combined one
    public var level: String
    public var scope: FactorScope
    public var routeId: String?
    public var quantity: FactorQuantity
    /// Route: per trip (s or % points). Pooled: per km. L1: per km per kg. Nil unless the gate is passed.
    public var effect: Double?
    /// Rides with / without the factor (in the comparison)
    public var n: Int
    public var nWithout: Int
    public var confidence: Double
    public var gate: FactorGate

    public init(factorId: String, level: String, scope: FactorScope, routeId: String?, quantity: FactorQuantity, effect: Double?,
                n: Int, nWithout: Int, confidence: Double, gate: FactorGate) {
        self.factorId = factorId
        self.level = level
        self.scope = scope
        self.routeId = routeId
        self.quantity = quantity
        self.effect = effect
        self.n = n
        self.nWithout = nWithout
        self.confidence = confidence
        self.gate = gate
    }

    /// Rides each side needs (T67)
    public var needed: Int { quantity.needed }
    public var passesGate: Bool { gate == .passed && effect != nil }
    /// "based on N rides"
    public var basedOnN: Int { n + nWithout }
    public var timeEffectS: Double? { quantity == .time && passesGate ? effect : nil }
    public var usedEffectPct: Double? { quantity == .used && passesGate ? effect : nil }
    /// M23: the per-kg effect is outside 0-3x the physics estimate
    public var uncertain: Bool { level.hasSuffix("Uncertain") }
}

/// One ride as the factors read it (the `ride` row with its factor columns).
public struct FactorRide: Equatable, Sendable {
    public var id: String
    public var routeId: String?
    public var startAt: Int64
    public var distanceM: Double
    public var totalS: Double?
    public var usedPct: Double?
    public var gapScooterS: Double
    public var headwindKmh: Double?
    /// dry / light / heavy; nil = no weather yet
    public var wet: String?
    public var rushHour: Bool
    /// workday / friday / saturday; nil = not classified yet
    public var dayType: String?
    public var loadKg: Double?
    /// The smart prompt (M4-05) thinks it was loaded but no tag: out of the unloaded baseline
    public var likelyLoaded: Bool
    public var elevGainM: Double?
    public var excluded: Bool
    /// ride / shortHop / discarded
    public var kind: String

    public init(id: String, routeId: String? = nil, startAt: Int64, distanceM: Double, totalS: Double? = nil, usedPct: Double? = nil,
                gapScooterS: Double = 0, headwindKmh: Double? = nil, wet: String? = nil, rushHour: Bool = false, dayType: String? = "workday",
                loadKg: Double? = nil, likelyLoaded: Bool = false, elevGainM: Double? = nil, excluded: Bool = false, kind: String = "ride") {
        self.id = id
        self.routeId = routeId
        self.startAt = startAt
        self.distanceM = distanceM
        self.totalS = totalS
        self.usedPct = usedPct
        self.gapScooterS = gapScooterS
        self.headwindKmh = headwindKmh
        self.wet = wet
        self.rushHour = rushHour
        self.dayType = dayType
        self.loadKg = loadKg
        self.likelyLoaded = likelyLoaded
        self.elevGainM = elevGainM
        self.excluded = excluded
        self.kind = kind
    }

    public var km: Double { distanceM / 1000 }

    /// Same filters as the usual range (M13): not excluded, a ride (no short hop), at least 1 km (T43); battery also needs
    /// no scooter gap over 60 s (T41).
    public func usable(_ q: FactorQuantity) -> Bool {
        guard kind == "ride", !excluded, distanceM >= T.t43BatteryPerKmAfterM else { return false }
        switch q {
        case .time: return (totalS ?? 0) > 0
        case .used: return (usedPct ?? 0) > 0 && gapScooterS <= T.t41CalibrationMaxGapS
        }
    }

    public func value(_ q: FactorQuantity) -> Double? { q == .time ? totalS : usedPct }

    public var gainPerKm: Double? { elevGainM.map { $0 / max(km, 0.001) } }
}

/// After-ride explanation (M24): the ride's factor effects, scaled to the real difference from the usual; the rest is "other".
public struct RideExplanation: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var factorId: String
        public var level: String
        public var timeS: Double?
        public var usedPct: Double?
        public var confidence: Double

        public init(factorId: String, level: String, timeS: Double?, usedPct: Double?, confidence: Double) {
            self.factorId = factorId
            self.level = level
            self.timeS = timeS
            self.usedPct = usedPct
            self.confidence = confidence
        }
    }

    public var items: [Item]
    /// This ride minus the route's usual median (nil: fewer than 3 / 5 other rides on the route, or no route)
    public var actualTimeS: Double?
    public var actualUsedPct: Double?
    public var otherTimeS: Double?
    public var otherPct: Double?
    /// Pattern W: the ride's weather is not there yet (the explanation is re-run when it arrives)
    public var weatherMissing: Bool

    public init(items: [Item] = [], actualTimeS: Double? = nil, actualUsedPct: Double? = nil, otherTimeS: Double? = nil,
                otherPct: Double? = nil, weatherMissing: Bool = false) {
        self.items = items
        self.actualTimeS = actualTimeS
        self.actualUsedPct = actualUsedPct
        self.otherTimeS = otherTimeS
        self.otherPct = otherPct
        self.weatherMissing = weatherMissing
    }
}

public enum FactorEngine {
    enum Member { case with, without, neither }

    /// One factor level
    struct Def {
        let id: String
        let level: String
        /// learned per route too (else pooled only)
        let routeScope: Bool
        /// pooled on the raw per-km value (a route property), not the difference from the route's median
        let raw: Bool
        /// nil = unknown (no weather yet), left out
        let member: (FactorRide) -> Member?
    }

    
    static let defs: [Def] = [
        Def(id: "W1", level: "head", routeScope: true, raw: false) { r in
            guard let h = r.headwindKmh else { return nil }
            return h >= FactorRules.headwindLevelKmh ? .with : (abs(h) < FactorRules.headwindLevelKmh ? .without : .neither)
        },
        Def(id: "W1", level: "tail", routeScope: true, raw: false) { r in
            guard let h = r.headwindKmh else { return nil }
            return h <= -FactorRules.headwindLevelKmh ? .with : (abs(h) < FactorRules.headwindLevelKmh ? .without : .neither)
        },
        Def(id: "W3", level: "wet", routeScope: false, raw: false) { r in
            guard let w = r.wet else { return nil }
            return w == "dry" ? .without : .with
        },
        Def(id: "R1", level: "hilly", routeScope: false, raw: true) { r in
            guard let g = r.gainPerKm else { return nil }
            return g >= FactorRules.hillyGainPerKm ? .with : .without
        },
        Def(id: "T1", level: "rush", routeScope: true, raw: false) { r in
            guard let d = r.dayType else { return nil }
            if r.rushHour { return .with }
            return d == "workday" ? .without : .neither
        },
        Def(id: "T2", level: "friday", routeScope: true, raw: false) { r in
            guard let d = r.dayType else { return nil }
            return d == "friday" ? .with : (d == "workday" ? .without : .neither)
        },
        Def(id: "T2", level: "saturday", routeScope: true, raw: false) { r in
            guard let d = r.dayType else { return nil }
            return d == "saturday" ? .with : (d == "workday" ? .without : .neither)
        },
        Def(id: "L1", level: "perKg", routeScope: false, raw: false) { r in
            if (r.loadKg ?? 0) > 0 { return .with }
            return r.likelyLoaded ? .neither : .without
        }
    ]

    /// The stratum value of a ride for a factor group (M24: stratified by the 2 strongest other factors)
    static func stratum(_ group: String, _ r: FactorRide) -> String {
        switch group {
        case "W1":
            guard let h = r.headwindKmh else { return "?" }
            return h >= FactorRules.headwindLevelKmh ? "h" : (h <= -FactorRules.headwindLevelKmh ? "t" : "c")
        case "W3": return r.wet.map { $0 == "dry" ? "d" : "w" } ?? "?"
        case "R1": return r.gainPerKm.map { $0 >= FactorRules.hillyGainPerKm ? "h" : "f" } ?? "?"
        case "T1": return r.rushHour ? "r" : "n"
        case "T2": return r.dayType ?? "?"
        case "L1": return (r.loadKg ?? 0) > 0 ? "l" : "n"
        default: return ""
        }
    }

    // MARK: Regression (confirmation)

    /// Feature order of the regression, with the factor group of each
    static let features: [(name: String, group: String)] = [("hw", "W1"), ("wet", "W3"), ("rush", "T1"), ("fri", "T2"), ("sat", "T2"),
                                                           ("kg", "L1"), ("gain", "R1")]

    struct Fit {
        /// per unit of each feature (nil = the feature had no spread and was left out)
        var beta: [Double?]
        /// per standard deviation (ranks the factors)
        var betaStd: [Double]

        func b(_ name: String) -> Double? {
            guard let i = FactorEngine.features.firstIndex(where: { $0.name == name }) else { return nil }
            return beta[i]
        }

        /// Factor groups, strongest first
        var ranking: [String] {
            var best: [String: Double] = [:]
            for (i, f) in FactorEngine.features.enumerated() { best[f.group] = max(best[f.group] ?? 0, abs(betaStd[i])) }
            return best.filter { $0.value > 1e-12 }.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { $0.key }
        }
    }

    /// Ridge regression on standardised features (columns without spread are left out). Nil under 3 rows.
    static func ridge(x: [[Double]], y: [Double], lambda: Double = FactorRules.ridgeLambda) -> Fit? {
        let n = y.count
        guard n >= 3, let width = x.first?.count else { return nil }
        var mean = [Double](repeating: 0, count: width), sd = [Double](repeating: 0, count: width)
        for j in 0..<width {
            mean[j] = x.map { $0[j] }.reduce(0, +) / Double(n)
            sd[j] = sqrt(x.map { ($0[j] - mean[j]) * ($0[j] - mean[j]) }.reduce(0, +) / Double(n))
        }
        let active = (0..<width).filter { sd[$0] > 1e-9 }
        var beta = [Double?](repeating: nil, count: width)
        var betaStd = [Double](repeating: 0, count: width)
        guard !active.isEmpty else { return Fit(beta: beta, betaStd: betaStd) }
        let ym = y.reduce(0, +) / Double(n)
        let z = x.map { row in active.map { (row[$0] - mean[$0]) / sd[$0] } }
        let k = active.count
        var a = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var rhs = [Double](repeating: 0, count: k)
        for i in 0..<n {
            for p in 0..<k {
                rhs[p] += z[i][p] * (y[i] - ym)
                for q in 0..<k { a[p][q] += z[i][p] * z[i][q] }
            }
        }
        for p in 0..<k { a[p][p] += lambda }
        guard let b = solve(a, rhs) else { return nil }
        for (p, j) in active.enumerated() {
            beta[j] = b[p] / sd[j]
            betaStd[j] = b[p]
        }
        return Fit(beta: beta, betaStd: betaStd)
    }

    /// Gaussian elimination with partial pivoting
    static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p)
            b.swapAt(c, p)
            for r in (c + 1)..<max(c + 1, n) {
                let f = a[r][c] / a[c][c]
                if f == 0 { continue }
                for k in c..<n { a[r][k] -= f * a[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<max(r + 1, n) { s -= a[r][k] * x[k] }
            x[r] = s / a[r][r]
        }
        return x
    }

    /// T76: shown only when the regression agrees on the sign and is within x2 of the main value.
    public static func confirms(main: Double, regression: Double?) -> Bool {
        guard let reg = regression, reg != 0, main != 0, (main > 0) == (reg > 0) else { return false }
        let ratio = abs(main) / abs(reg)
        return ratio >= 1 / T.t76FactorConfirmRatio && ratio <= T.t76FactorConfirmRatio
    }

    // MARK: Helpers

    static func median(_ v: [Double]) -> Double? { Geo.median(v) }

    /// Median absolute deviation (M15 variation gate)
    public static func mad(_ v: [Double]) -> Double {
        guard let m = median(v) else { return 0 }
        return median(v.map { abs($0 - m) }) ?? 0
    }

    /// M24 main: weighted mean of the per-stratum median differences (weight = na x nb / (na + nb)). Strata with only one
    /// side are skipped; with none left, one stratum less is used.
    static func matched(_ items: [(value: Double, member: Member, strata: [String])]) -> Double? {
        let maxDepth = items.first?.strata.count ?? 0
        for depth in stride(from: maxDepth, through: 0, by: -1) {
            var groups: [String: (a: [Double], b: [Double])] = [:]
            for it in items where it.member != .neither {
                let key = it.strata.prefix(depth).joined(separator: "|")
                var g = groups[key] ?? ([], [])
                if it.member == .with { g.a.append(it.value) } else { g.b.append(it.value) }
                groups[key] = g
            }
            var num = 0.0, den = 0.0
            for (_, g) in groups where !g.a.isEmpty && !g.b.isEmpty {
                guard let ma = median(g.a), let mb = median(g.b) else { continue }
                let w = Double(g.a.count * g.b.count) / Double(g.a.count + g.b.count)
                num += w * (ma - mb)
                den += w
            }
            if den > 0 { return num / den }
        }
        return nil
    }

    static func confidence(n: Int, nWithout: Int, needed: Int, main: Double, regression: Double) -> Double {
        let share = min(1, Double(min(n, nWithout)) / Double(2 * needed))
        let agree = 1 - min(1, abs(log2(abs(main) / abs(regression))))
        return max(0.1, min(1, 0.5 * share + 0.5 * agree))
    }

    // MARK: Compute

    /// Per quantity: the rides, their per-km values, the difference from their route's median, and the two regressions.
    struct Prepared {
        var rides: [FactorRide]
        var perKm: [String: Double] = [:]
        var dev: [String: Double] = [:]
        var gainDev: [String: Double] = [:]
        /// within routes (all factors but hills)
        var fitWithin: Fit?
        /// raw per km (hills)
        var fitRaw: Fit?
    }

    static func prepare(_ all: [FactorRide], _ q: FactorQuantity, nowMs: Int64) -> Prepared {
        let rides = all.filter { $0.usable(q) && $0.startAt >= nowMs - FactorRules.windowMs && $0.startAt <= nowMs + OutsideTime.dayMs }
        var p = Prepared(rides: rides)
        var byRoute: [String: [FactorRide]] = [:]
        for r in rides { byRoute[r.routeId ?? "-", default: []].append(r) }
        for (_, list) in byRoute {
            let values = list.compactMap { r in r.value(q).map { $0 / r.km } }
            let med = median(values) ?? 0
            let gains = list.compactMap(\.gainPerKm)
            let gmed = median(gains) ?? 0
            for r in list {
                guard let v = r.value(q) else { continue }
                p.perKm[r.id] = v / r.km
                p.dev[r.id] = v / r.km - med
                p.gainDev[r.id] = (r.gainPerKm ?? gmed) - gmed
            }
        }
        // the weather features join only when enough rides have weather; then only those rides are used
        let withWeather = rides.filter { $0.headwindKmh != nil && $0.wet != nil }
        let useWeather = withWeather.count >= FactorRules.regressionMinWeatherRides
        let rows = useWeather ? withWeather : rides
        let gainDev = p.gainDev
        func x(_ r: FactorRide, raw: Bool) -> [Double] {
            [useWeather ? (r.headwindKmh ?? 0) : 0, useWeather ? (r.wet == "dry" ? 0 : 1) : 0, r.rushHour ? 1 : 0,
             r.dayType == "friday" ? 1 : 0, r.dayType == "saturday" ? 1 : 0, r.likelyLoaded ? 0 : (r.loadKg ?? 0),
             raw ? (r.gainPerKm ?? 0) : (gainDev[r.id] ?? 0)]
        }
        let dev = p.dev, perKm = p.perKm
        let fitWithin = ridge(x: rows.map { x($0, raw: false) }, y: rows.map { dev[$0.id] ?? 0 })
        let fitRaw = ridge(x: rows.map { x($0, raw: true) }, y: rows.map { perKm[$0.id] ?? 0 })
        p.fitWithin = fitWithin
        p.fitRaw = fitRaw
        return p
    }

    /// What the regression says the factor level is worth per km (nil: it cannot tell).
    static func implied(_ def: Def, _ items: [FactorRide], _ p: Prepared) -> Double? {
        func meanOf(_ m: Member, _ f: (FactorRide) -> Double?) -> Double? {
            let v = items.filter { def.member($0) == m }.compactMap(f)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        let fit = def.raw ? p.fitRaw : p.fitWithin
        guard let fit else { return nil }
        switch (def.id, def.level) {
        case ("W1", _):
            guard let b = fit.b("hw"), let a = meanOf(.with, { $0.headwindKmh }), let c = meanOf(.without, { $0.headwindKmh }) else { return nil }
            return b * (a - c)
        case ("W3", _): return fit.b("wet")
        case ("R1", _):
            guard let b = fit.b("gain"), let a = meanOf(.with, { $0.gainPerKm }), let c = meanOf(.without, { $0.gainPerKm }) else { return nil }
            return b * (a - c)
        case ("T1", _): return fit.b("rush")
        case ("T2", "friday"): return fit.b("fri")
        case ("T2", _): return fit.b("sat")
        case ("L1", _): return fit.b("kg")
        default: return nil
        }
    }

    struct Outcome {
        var effect: Double?
        var n: Int
        var nWithout: Int
        var gate: FactorGate
        var confidence: Double
        var level: String
    }

    /// One comparison with its gate. `value` = the quantity of a ride in this scope; `perKmScale` turns the effect into
    /// the regression's per-km unit (route: 1 / route km; pooled: 1).
    static func evaluate(def: Def, member: (FactorRide) -> Member?, rides: [FactorRide], value: (FactorRide) -> Double?, q: FactorQuantity,
                         strataGroups: [String], regression: Double?, perKmScale: Double, perKg: Bool,
                         base: (FactorRide) -> Double? = { _ in nil }) -> Outcome {
        var items: [(value: Double, member: Member, strata: [String])] = []
        var withRides: [FactorRide] = []
        var nWithout = 0
        var baseValues: [Double] = []
        for r in rides {
            guard let m = member(r), m != .neither, let v = value(r) else { continue }
            items.append((v, m, strataGroups.map { stratum($0, r) }))
            if m == .with {
                withRides.append(r)
            } else {
                nWithout += 1
                if let b = base(r) { baseValues.append(b) }
            }
        }
        let n = withRides.count
        var out = Outcome(effect: nil, n: n, nWithout: nWithout, gate: .notEnoughRides, confidence: FactorGate.notEnoughRides.code, level: def.level)
        guard n >= q.needed, nWithout >= q.needed, let main = matched(items) else { return out }
        guard abs(main) > mad(items.map { $0.value }) else {
            out.gate = .withinNoise
            out.confidence = FactorGate.withinNoise.code
            return out
        }
        var shown = main
        var reg = regression
        if perKg {
            // M23: per kg = the loaded-vs-unloaded effect / the loaded rides' median kg
            let kg = median(withRides.compactMap(\.loadKg)) ?? 0
            guard kg > 0 else { return out }
            shown = main / kg
            if q == .used, let baseline = median(baseValues), baseline > 0 {
                let physics = 1 / (FactorRules.riderDefaultKg + FactorRules.scooterKg) * FactorRules.rollingShare
                let rel = shown / baseline
                if rel < 0 || rel > FactorRules.plausibleFactor * physics { out.level = "perKgUncertain" }
            }
        } else {
            reg = regression.map { $0 / perKmScale }
        }
        guard confirms(main: shown, regression: reg), let r = reg else {
            out.gate = .notConfirmed
            out.confidence = FactorGate.notConfirmed.code
            return out
        }
        out.effect = shown
        out.gate = .passed
        out.confidence = confidence(n: n, nWithout: nWithout, needed: q.needed, main: shown, regression: r)
        if out.level.hasSuffix("Uncertain") { out.confidence = min(out.confidence, 0.3) }
        return out
    }

    /// Two factor levels found together in more than 80% of their rides, fewer than 3 rides apart (M24 combined)
    static func togetherPairs(_ defs: [Def], _ rides: [FactorRide]) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for i in 0..<defs.count {
            for j in (i + 1)..<max(i + 1, defs.count) where defs[i].id != defs[j].id {
                var a = Set<String>(), b = Set<String>()
                for r in rides {
                    guard let mi = defs[i].member(r), let mj = defs[j].member(r) else { continue }
                    if mi == .with { a.insert(r.id) }
                    if mj == .with { b.insert(r.id) }
                }
                let union = a.union(b)
                guard !a.isEmpty, !b.isEmpty else { continue }
                let together = a.intersection(b).count
                let apart = union.count - together
                if Double(together) / Double(union.count) > FactorRules.combinedShare && apart < FactorRules.combinedApart { pairs.append((i, j)) }
            }
        }
        return pairs
    }

    /// Every factor effect for these rides: per route (W1, T1, T2) and, with `pooled`, per km over all routes (all factors).
    /// Simulated rides are given in their own call with `pooled: false`, so they never mix with real ones.
    public static func compute(rides all: [FactorRide], nowMs: Int64, pooled: Bool = true) -> [FactorEffect] {
        var out: [FactorEffect] = []
        for q in FactorQuantity.allCases {
            let p = prepare(all, q, nowMs: nowMs)
            let ranking = p.fitWithin?.ranking ?? []
            func strata(excluding ids: Set<String>) -> [String] { Array(ranking.filter { !ids.contains($0) }.prefix(2)) }

            func run(_ defs: [Def], rides: [FactorRide], scope: FactorScope, routeId: String?, value: @escaping (FactorRide) -> Double?,
                     rawValue: @escaping (FactorRide) -> Double?,
                     perKmScale: Double) {
                let pairs = togetherPairs(defs, rides)
                let joined = Set(pairs.flatMap { [$0.0, $0.1] })
                for (i, def) in defs.enumerated() {
                    if joined.contains(i) {
                        let n = rides.filter { def.member($0) == .with && value($0) != nil }.count
                        let nw = rides.filter { def.member($0) == .without && value($0) != nil }.count
                        out.append(FactorEffect(factorId: def.id, level: def.level, scope: scope, routeId: routeId, quantity: q, effect: nil,
                                                n: n, nWithout: nw, confidence: FactorGate.combined.code, gate: .combined))
                        continue
                    }
                    let o = evaluate(def: def, member: def.member, rides: rides, value: def.raw ? rawValue : value, q: q,
                                     strataGroups: strata(excluding: [def.id]), regression: implied(def, rides, p), perKmScale: perKmScale,
                                     perKg: def.id == "L1", base: { p.perKm[$0.id] })
                    out.append(FactorEffect(factorId: def.id, level: o.level, scope: scope, routeId: routeId, quantity: q, effect: o.effect,
                                            n: o.n, nWithout: o.nWithout, confidence: o.confidence, gate: o.gate))
                }
                for (i, j) in pairs {
                    let a = defs[i], b = defs[j]
                    let member: (FactorRide) -> Member? = { r in
                        guard let ma = a.member(r), let mb = b.member(r) else { return nil }
                        if ma == .with && mb == .with { return .with }
                        if ma == .without && mb == .without { return .without }
                        return .neither
                    }
                    let both = rides.filter { member($0) != nil }
                    var reg: Double?
                    if let ra = implied(a, both, p), let rb = implied(b, both, p) { reg = ra + rb }
                    let combinedDef = Def(id: a.id + "+" + b.id, level: a.level + "+" + b.level, routeScope: a.routeScope && b.routeScope,
                                          raw: a.raw || b.raw, member: member)
                    let o = evaluate(def: combinedDef, member: member, rides: rides, value: combinedDef.raw ? rawValue : value, q: q,
                                     strataGroups: strata(excluding: [a.id, b.id]), regression: reg, perKmScale: perKmScale, perKg: false)
                    out.append(FactorEffect(factorId: combinedDef.id, level: combinedDef.level, scope: scope, routeId: routeId, quantity: q,
                                            effect: o.effect, n: o.n, nWithout: o.nWithout, confidence: o.confidence, gate: o.gate))
                }
            }

            if pooled {
                run(defs, rides: p.rides, scope: .pooled, routeId: nil, value: { p.dev[$0.id] }, rawValue: { p.perKm[$0.id] }, perKmScale: 1)
            }
            var routes: [String: [FactorRide]] = [:]
            for r in p.rides { if let id = r.routeId { routes[id, default: []].append(r) } }
            for id in routes.keys.sorted() {
                guard let list = routes[id] else { continue }
                let km = median(list.map(\.km)) ?? 1
                run(defs.filter(\.routeScope), rides: list, scope: .route, routeId: id, value: { $0.value(q) }, rawValue: { $0.value(q) },
                    perKmScale: 1 / max(km, 0.001))
            }
        }
        return out
    }

    // MARK: After-ride explanation

    /// The ride's factor effects (route effect when it passes, else pooled per km x the ride's km; load x kg), scaled so they
    /// do not explain more than the real difference from the route's usual median; the rest is "other".
    public static func explain(ride: FactorRide, routeRides: [FactorRide], effects: [FactorEffect], nowMs: Int64) -> RideExplanation {
        var ex = RideExplanation(weatherMissing: ride.headwindKmh == nil && ride.wet == nil)
        let others = routeRides.filter { $0.id != ride.id && !$0.excluded && $0.kind == "ride" && $0.startAt >= nowMs - Int64(T.t64UsualRangeDays * 86_400_000) }
            .sorted { $0.startAt > $1.startAt }.prefix(T.t64UsualRangeRides)
        if ride.routeId != nil, ride.usable(.time), let t = ride.totalS {
            let v = others.filter { $0.usable(.time) }.compactMap(\.totalS)
            if v.count >= T.t67EnoughTimeRides, let m = median(v) { ex.actualTimeS = t - m }
        }
        if ride.routeId != nil, ride.usable(.used), let u = ride.usedPct {
            let v = others.filter { $0.usable(.used) }.compactMap(\.usedPct)
            if v.count >= T.t67EnoughBatteryRides, let m = median(v) { ex.actualUsedPct = u - m }
        }

        func pick(_ id: String, _ level: String, _ q: FactorQuantity) -> (Double, Double)? {
            let match = effects.filter { $0.factorId == id && $0.quantity == q && $0.passesGate && ($0.level == level || (id == "L1" && $0.level.hasPrefix("perKg"))) }
            if let r = match.first(where: { $0.scope == .route && $0.routeId != nil && $0.routeId == ride.routeId }), let e = r.effect {
                return (e, r.confidence)
            }
            if let r = match.first(where: { $0.scope == .pooled }), let e = r.effect {
                let scale = id == "L1" ? ride.km * (ride.loadKg ?? 0) : ride.km
                return (e * scale, r.confidence)
            }
            return nil
        }

        var levels: [(id: String, level: String)] = []
        for def in defs where def.member(ride) == .with { levels.append((def.id, def.level)) }
        // combined factors: the ride has both parts
        var used = Set<Int>()
        var pairs: [(id: String, level: String)] = []
        for e in effects where e.factorId.contains("+") && e.passesGate {
            let ids = e.factorId.split(separator: "+").map(String.init)
            let lv = e.level.split(separator: "+").map(String.init)
            guard ids.count == 2, lv.count == 2 else { continue }
            let ia = levels.firstIndex { $0.id == ids[0] && $0.level == lv[0] }
            let ib = levels.firstIndex { $0.id == ids[1] && $0.level == lv[1] }
            if let ia, let ib, !pairs.contains(where: { $0.id == e.factorId && $0.level == e.level }) {
                used.insert(ia)
                used.insert(ib)
                pairs.append((e.factorId, e.level))
            }
        }
        let all = levels.enumerated().filter { !used.contains($0.offset) }.map { $0.element } + pairs
        for (id, level) in all {
            let t = pick(id, level, .time)
            let u = pick(id, level, .used)
            guard t != nil || u != nil else { continue }
            ex.items.append(RideExplanation.Item(factorId: id, level: level, timeS: t?.0, usedPct: u?.0, confidence: max(t?.1 ?? 0, u?.1 ?? 0)))
        }

        func scale(_ get: (RideExplanation.Item) -> Double?, _ set: (inout RideExplanation.Item, Double) -> Void, actual: Double?) -> Double? {
            guard let d = actual else { return nil }
            let s = ex.items.compactMap(get).reduce(0, +)
            if s != 0, (s > 0) == (d > 0), abs(s) > abs(d) {
                let f = d / s
                for i in ex.items.indices { if let v = get(ex.items[i]) { set(&ex.items[i], v * f) } }
                return 0
            }
            return d - s
        }
        let otherTime = scale({ $0.timeS }, { $0.timeS = $1 }, actual: ex.actualTimeS)
        ex.otherTimeS = otherTime
        let otherPct = scale({ $0.usedPct }, { $0.usedPct = $1 }, actual: ex.actualUsedPct)
        ex.otherPct = otherPct
        return ex
    }
}
