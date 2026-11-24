import Foundation

/// N11-1 · E4 / V08 Tyre-pressure hint (owner 23 Nov, revised "auto-first", accepted; charts reports/expansion/n11-1-*.png).
///
/// Watches the energy a ride takes per km (Wh, not battery %, so battery wear is not mistaken for drag) on the rider's usual
/// routes and compares each ride only with earlier rides on the SAME route in SIMILAR conditions, so the app itself rules out:
/// cold, wind / rain, speed, stop-and-go, gear, a detour and extra load (estimated from pull vs acceleration, `LoadEstimate`).
/// Clean data only: rides with gaps, a wheel that reads more km than the GPS, or no saved route are skipped; a firmware change,
/// a battery swap or a lasting drop starts a new normal. No hint before ~10 clean rides on this scooter.
///
/// Steps (every tap optional): slow creep over 5 rides -> tyre hint · sudden jump over 2 rides -> brake / wheel hint ·
/// rise + motor hotter than usual -> shop. No tap and still high after 3 rides -> the next step. Use drops back -> "Back to normal".
/// Universal (P-6): every number is learned per scooter; the only fixed numbers are the rule constants below.
public enum TyreType: String, Codable, Sendable {
    case air, solid, unknown
}

public extension KnownScooters {
    /// N11-1: the tyre type from the model (RND G100 / G500: air tyres); unknown -> "pressure, or wear if solid"
    static func tyre(model: String?) -> TyreType {
        switch model ?? "" {
        case "RND G100", "RND G500": return .air
        default: return .unknown
        }
    }
}

/// One ride, as the hint sees it (the app fills it from the ride row and its readings)
public struct EnergyRide: Codable, Equatable, Sendable {
    public var rideId: String
    public var day: Int
    public var routeId: String?
    public var distanceKm: Double
    /// Raw Wh from the scooter's own volts x amps (never battery %)
    public var energyWh: Double
    public var airTempC: Double?
    public var headwindKmh: Double?
    public var wet: Bool
    public var avgKmh: Double?
    public var stopsPerKm: Double?
    /// The gear used most (nil = unknown)
    public var mainGear: Int?
    /// Seconds with no scooter readings or no GPS
    public var gapS: Double
    /// Scooter km ÷ GPS km for this ride (nil = no GPS)
    public var wheelOverGps: Double?
    /// Pull per unit of acceleration (`LoadEstimate.pull`), nil when the ride had too few clean speed-ups
    public var pull: Double?
    /// Motor temperature rise over the ride (°C)
    public var motorRiseC: Double?
    public var firmware: String?

    public init(rideId: String, day: Int, routeId: String?, distanceKm: Double, energyWh: Double, airTempC: Double? = nil,
                headwindKmh: Double? = nil, wet: Bool = false, avgKmh: Double? = nil, stopsPerKm: Double? = nil, mainGear: Int? = nil,
                gapS: Double = 0, wheelOverGps: Double? = nil, pull: Double? = nil, motorRiseC: Double? = nil, firmware: String? = nil) {
        self.rideId = rideId; self.day = day; self.routeId = routeId; self.distanceKm = distanceKm; self.energyWh = energyWh
        self.airTempC = airTempC; self.headwindKmh = headwindKmh; self.wet = wet; self.avgKmh = avgKmh; self.stopsPerKm = stopsPerKm
        self.mainGear = mainGear; self.gapS = gapS; self.wheelOverGps = wheelOverGps; self.pull = pull; self.motorRiseC = motorRiseC
        self.firmware = firmware
    }

    public var whPerKm: Double { distanceKm > 0 ? energyWh / distanceKm : 0 }
}

/// N11-1: the rules' constants (not personal values: the rider's own normal and noise are learned)
public enum EnergyRules {
    public static let learningRides = 10
    public static let minComparable = 3
    public static let maxGapS = 30.0
    public static let minKm = 1.0
    /// Wheel km more than 10 % over GPS km (or 15 % under: GPS trouble) = not clean
    public static let wheelOverGpsMax = 1.10
    public static let wheelOverGpsMin = 0.85
    /// Similar conditions
    public static let tempBandC = 5.0
    public static let windBandKmh = 8.0
    public static let speedBand = 0.10
    public static let stopsBand = 0.5
    public static let distanceBand = 0.10
    public static let pullBand = 0.08
    /// The smallest rise ever called a rise; the learned noise + 10 % (safety margin) wins when larger
    public static let minThreshold = 0.06
    public static let creepRides = 5
    public static let jumpRides = 2
    public static let stepRides = 3
    /// Each "it's fine" makes this scooter half as sensitive again
    public static let fineBoost = 0.5
    public static let poolCap = 240
}

public enum EnergySkip: String, Codable, Sendable {
    case gaps, short, wheelOverGps, noRoute, detour, noMatch, firmware
}

public enum EnergyStep: String, Codable, Sendable {
    /// Nothing to say
    case quiet
    /// Slow creep: check tyre pressure
    case tyre
    /// Sudden jump, or the pressure was fine: lift the wheel and spin it
    case brakeWheel
    /// Still high after the hands-on checks, or rise + motor hot: worth a shop check (an open finding)
    case shop
    /// "Pumped it": watching the next rides to confirm
    case pumped
}

public struct EnergyScooter: Codable, Equatable, Sendable {
    /// The normal: clean rides that matched (oldest first)
    public var pool: [EnergyRide] = []
    public var cleanRides = 0
    /// Ratios of the last compared rides (ride Wh/km ÷ similar rides' median), oldest first
    public var ratios: [Double] = []
    public var lastRiseC: [Double] = []
    public var fines = 0
    public var step: EnergyStep = .quiet
    public var stepRides = 0
    /// Both hands-on checks were fine: the next rise goes straight to the shop hint
    public var checkedBoth = false
    public var firmware: String?
    /// "Back to normal: +1.5 km of range" waiting to be shown once (km)
    public var backToNormalKm: Double?
    public var backAfterPump = false
    public var motorHot = false
    public var sinceDay: Int?

    public init() {}
}

public struct EnergyBook: Codable, Equatable, Sendable {
    public var scooters: [String: EnergyScooter] = [:]
    public init() {}
    public static let settingKey = "tyre.energyBook"
}

public enum EnergyHint {
    // MARK: clean data

    public static func skip(_ r: EnergyRide, firmwareNow: String?) -> EnergySkip? {
        if r.gapS > EnergyRules.maxGapS { return .gaps }
        if r.distanceKm < EnergyRules.minKm || r.energyWh <= 0 { return .short }
        if let w = r.wheelOverGps, w > EnergyRules.wheelOverGpsMax || w < EnergyRules.wheelOverGpsMin { return .wheelOverGps }
        if r.routeId == nil { return .noRoute }
        return nil
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Same route, similar conditions (each factor only compared when both rides know it)
    public static func similar(_ a: EnergyRide, _ b: EnergyRide) -> Bool {
        guard a.routeId == b.routeId else { return false }
        func near(_ x: Double?, _ y: Double?, _ band: Double) -> Bool { guard let x, let y else { return true }; return abs(x - y) <= band }
        func nearRel(_ x: Double?, _ y: Double?, _ band: Double) -> Bool { guard let x, let y, y > 0 else { return true }; return abs(x / y - 1) <= band }
        return near(a.airTempC, b.airTempC, EnergyRules.tempBandC)
            && near(a.headwindKmh, b.headwindKmh, EnergyRules.windBandKmh)
            && a.wet == b.wet
            && nearRel(a.avgKmh, b.avgKmh, EnergyRules.speedBand)
            && near(a.stopsPerKm, b.stopsPerKm, EnergyRules.stopsBand)
            && (a.mainGear == nil || b.mainGear == nil || a.mainGear == b.mainGear)
            && nearRel(a.pull, b.pull, EnergyRules.pullBand)
    }

    /// A detour: the ride is more than 10 % longer or shorter than this route's usual length
    public static func isDetour(_ r: EnergyRide, pool: [EnergyRide]) -> Bool {
        guard let usual = median(pool.filter { $0.routeId == r.routeId }.map(\.distanceKm)) else { return false }
        return abs(r.distanceKm / usual - 1) > EnergyRules.distanceBand
    }

    /// This ride's Wh/km ÷ the median of similar rides in the normal (nil = fewer than 3 similar rides)
    public static func ratio(_ r: EnergyRide, pool: [EnergyRide]) -> Double? {
        let same = pool.filter { similar(r, $0) && $0.rideId != r.rideId }.map(\.whPerKm)
        guard same.count >= EnergyRules.minComparable, let m = median(same), m > 0 else { return nil }
        return r.whPerKm / m
    }

    /// The scooter's own noise: how far a normal ride sits from its similar rides (90th percentile), + 10 % margin
    public static func threshold(_ s: EnergyScooter) -> Double {
        var devs: [Double] = []
        for r in s.pool { if let x = ratio(r, pool: s.pool) { devs.append(abs(x - 1)) } }
        let noise = devs.count >= 5 ? devs.sorted()[Int(Double(devs.count - 1) * 0.9)] : 0
        return max(EnergyRules.minThreshold, noise * 1.1) * (1 + EnergyRules.fineBoost * Double(s.fines))
    }

    /// km more per charge when the use comes back down from `highRatio` to the normal (pack in Wh)
    public static func kmGained(packWh: Double, normalWhPerKm: Double, highRatio: Double) -> Double {
        guard normalWhPerKm > 0, highRatio > 0 else { return 0 }
        return packWh / normalWhPerKm - packWh / (normalWhPerKm * highRatio)
    }

    public static func normalWhPerKm(_ s: EnergyScooter) -> Double? { median(s.pool.map(\.whPerKm)) }

    /// The level of the current rise: the median of the trailing high rides (at least the last 2)
    static func currentLevel(_ s: EnergyScooter, _ t: Double) -> Double {
        var tail: [Double] = []
        for x in s.ratios.reversed() { if x > 1 + t / 2 { tail.append(x) } else { break } }
        if tail.count < 2 { tail = Array(s.ratios.suffix(2)) }
        return median(tail) ?? 1
    }

    /// A new normal from here: the rides from now on teach it (no learning silence again for this scooter)
    static func newNormal(_ s: inout EnergyScooter) {
        s.pool = []
        s.ratios = []
        s.lastRiseC = []
    }

    // MARK: one ride

    public struct Outcome: Equatable, Sendable {
        public var skipped: EnergySkip?
        public var ratio: Double?
        public var stepBefore: EnergyStep
        public var stepAfter: EnergyStep
    }

    /// Feeds one ended ride. `packWh` turns "back to normal" into km of range.
    public static func ride(_ book: inout EnergyBook, scooterId: String, _ r: EnergyRide, packWh: Double?) -> Outcome {
        var s = book.scooters[scooterId] ?? EnergyScooter()
        let before = s.step
        defer { book.scooters[scooterId] = s }
        // a firmware change starts a new normal (A29)
        if let fw = r.firmware {
            if let known = s.firmware, known != fw { s = EnergyScooter(); s.firmware = fw; return Outcome(skipped: .firmware, ratio: nil, stepBefore: before, stepAfter: s.step) }
            s.firmware = fw
        }
        if let why = skip(r, firmwareNow: s.firmware) { return Outcome(skipped: why, ratio: nil, stepBefore: before, stepAfter: s.step) }
        if isDetour(r, pool: s.pool) { return Outcome(skipped: .detour, ratio: nil, stepBefore: before, stepAfter: s.step) }
        s.cleanRides += 1
        guard let raw = ratio(r, pool: s.pool) else {
            s.pool.append(r)   // learning this route / these conditions
            trimPool(&s)
            return Outcome(skipped: .noMatch, ratio: nil, stepBefore: before, stepAfter: s.step)
        }
        let x = raw
        let t = threshold(s)
        s.ratios.append(x)
        if s.ratios.count > 20 { s.ratios.removeFirst(s.ratios.count - 20) }
        if let rise = r.motorRiseC { s.lastRiseC.append(rise); if s.lastRiseC.count > 20 { s.lastRiseC.removeFirst() } }
        // only rides near the normal teach the normal (a creep must not drag the normal up with it)
        if abs(x - 1) <= t / 2 { s.pool.append(r); trimPool(&s) }

        let learning = s.cleanRides < EnergyRules.learningRides
        let last = Array(s.ratios.suffix(EnergyRules.creepRides))
        let high = { (v: Double) in v > 1 + t }
        let backDown = s.ratios.suffix(2).count == 2 && s.ratios.suffix(2).allSatisfy { $0 <= 1 + t / 2 }

        // a lasting drop (e.g. new tyres, lighter rider) = the new normal, quietly
        if last.count == EnergyRules.creepRides, last.allSatisfy({ $0 < 1 - t }) {
            newNormal(&s)
            return Outcome(skipped: nil, ratio: x, stepBefore: before, stepAfter: s.step)
        }

        switch s.step {
        case .quiet:
            guard !learning else { break }
            let jump = s.ratios.count >= EnergyRules.jumpRides + 3
                && s.ratios.suffix(EnergyRules.jumpRides).allSatisfy({ $0 > 1 + 2 * t })
                && (median(Array(s.ratios.dropLast(EnergyRules.jumpRides).suffix(3))) ?? 1) <= 1 + t / 2
            let creep = last.count == EnergyRules.creepRides && last.allSatisfy({ $0 > 1 + t / 2 }) && (median(last) ?? 1) > 1 + t
            if jump || creep {
                s.motorHot = motorHotter(s)
                s.step = s.checkedBoth || s.motorHot ? .shop : (jump ? .brakeWheel : .tyre)
                s.stepRides = 0
                s.sinceDay = r.day
            }
        case .tyre, .brakeWheel, .pumped:
            if backDown {
                var prior = s
                prior.ratios = Array(s.ratios.dropLast(2))
                let level = currentLevel(prior, t)
                s.backToNormalKm = packWh.flatMap { p in normalWhPerKm(s).map { kmGained(packWh: p, normalWhPerKm: $0, highRatio: level) } }
                s.backAfterPump = s.step == .pumped
                s.step = .quiet
                s.ratios = []
            } else if high(x) {
                s.stepRides += 1
                if s.stepRides >= EnergyRules.stepRides {   // no tap and still high after 3 rides: the next step
                    s.step = s.step == .brakeWheel ? .shop : .brakeWheel
                    s.stepRides = 0
                }
            }
        case .shop:
            if backDown { s.step = .quiet; s.ratios = [] }
        }
        return Outcome(skipped: nil, ratio: x, stepBefore: before, stepAfter: s.step)
    }

    /// B111 (hotfix .11): the ride's `wet` / `wetOverride` columns are TEXT ("dry", "rain", …). The rider's override wins; anything
    /// but "dry" is wet; nothing known = dry.
    public static func isWet(override: String?, weather: String?) -> Bool {
        guard let w = override ?? weather else { return false }
        return w != "dry"
    }

    /// The motor ran hotter than this scooter's usual on the high rides (last 2 rises above the earlier ones' 90th percentile + 10 %)
    static func motorHotter(_ s: EnergyScooter) -> Bool {
        guard s.lastRiseC.count >= 8 else { return false }
        let earlier = s.lastRiseC.dropLast(2).sorted()
        let p90 = earlier[Int(Double(earlier.count - 1) * 0.9)]
        return s.lastRiseC.suffix(2).allSatisfy { $0 > p90 * 1.1 + 1 }
    }

    private static func trimPool(_ s: inout EnergyScooter) {
        if s.pool.count > EnergyRules.poolCap { s.pool.removeFirst(s.pool.count - EnergyRules.poolCap) }
    }

    // MARK: the rider's optional taps

    public enum Tap: String, Sendable {
        /// "Checked, pressure is fine" (logged in the service book) -> the brake / wheel check
        case pressureFine
        /// "Pumped it" -> watch the next rides
        case pumped
        /// "Fine too" (wheel spins freely) -> the current level is the new normal; the next rise goes to the shop hint
        case fineToo
        /// "Found it" (brake rubbing, wheel) -> watch for back to normal
        case foundIt
        /// Shop finding: "I fixed it"
        case fixed
        /// Shop finding: "Checked, it's fine" -> new normal, less sensitive
        case checkedFine
    }

    public static func tap(_ book: inout EnergyBook, scooterId: String, _ tap: Tap) {
        guard var s = book.scooters[scooterId] else { return }
        switch tap {
        case .pressureFine: s.step = .brakeWheel; s.stepRides = 0
        case .pumped: s.step = .pumped; s.stepRides = 0
        case .foundIt, .fixed: s.step = .pumped; s.stepRides = 0
        case .fineToo, .checkedFine:
            // the current Wh/km is the new normal (learned again from the next rides), and this scooter is less sensitive
            newNormal(&s)
            s.fines += 1
            s.checkedBoth = tap == .fineToo
            s.step = .quiet
            s.stepRides = 0
        }
        book.scooters[scooterId] = s
    }

    /// A battery swap / replaced tyre (Log what I did) or Start fresh: a new normal from zero for this scooter
    public static func reset(_ book: inout EnergyBook, scooterId: String) {
        book.scooters[scooterId] = EnergyScooter()
    }

    /// The "back to normal" line, once
    public static func takeBackToNormal(_ book: inout EnergyBook, scooterId: String) -> String? {
        guard var s = book.scooters[scooterId], let km = s.backToNormalKm else { return nil }
        s.backToNormalKm = nil
        book.scooters[scooterId] = s
        return EnergyCopy.backToNormal(km: km, afterPump: s.backAfterPump)
    }
}

/// N11-1 wording (phone-glance, P-7)
public enum EnergyCopy {
    public struct Text: Equatable, Sendable {
        public var part: MaintPart
        /// The row line on the Tyres / Brakes / Motor tile
        public var row: String
        public var found: String
        public var what: String
    }

    public static func text(_ step: EnergyStep, tyre: TyreType, motorHot: Bool = false) -> Text? {
        let lead = "Using more battery than usual on the same routes"
        switch step {
        case .quiet: return nil
        case .tyre:
            let what: String
            switch tyre {
            case .air: what = "Check tyre pressure."
            case .solid: what = "Check tyre wear."
            case .unknown: what = "Check tyre pressure, or wear if the tyres are solid."
            }
            return Text(part: .tyres, row: tyre == .solid ? "Check tyre wear" : "Check tyre pressure",
                        found: lead + ": " + what.prefix(1).lowercased() + String(what.dropFirst()), what: what)
        case .brakeWheel:
            return Text(part: .brakes, row: "Check the wheels turn freely",
                        found: lead + ", and it isn't the tyres.",
                        what: "Lift the wheel and spin it, it should turn freely. A rubbing brake or a tight wheel uses more battery.")
        case .shop:
            return Text(part: motorHot ? .motor : .tyres, row: "Worth a shop check",
                        found: motorHot ? lead + ", and the motor runs hotter than usual." : lead + ", after the checks.",
                        what: "Worth a shop check: show them the service book.")
        case .pumped:
            return Text(part: .tyres, row: "Watching the next rides", found: "Watching if the battery use comes back down.", what: "Nothing to do. Ride as usual.")
        }
    }

    public static func backToNormal(km: Double, afterPump: Bool) -> String {
        let k = max(0.5, (km * 2).rounded() / 2)
        let n = k == k.rounded() ? String(format: "%.0f", k) : String(format: "%.1f", k)
        return (afterPump ? "Back to normal since you pumped" : "Back to normal") + ": +\(n) km of range"
    }
}

/// N11-1: extra load, estimated from the pull it takes to speed up (instead of asking "carrying more?").
/// Electric power ÷ speed = the force at the wheel (times the drive's efficiency); during speed-ups that force grows with
/// mass × acceleration. The slope of force over acceleration ("pull") is mass ÷ efficiency: a heavier load pulls more per m/s².
/// Compared only with the same scooter's own pull, so the unknown efficiency cancels out.
/// NOTE: built and tested on synthetic rides only; it must be checked against the owner's real export before it is trusted.
public enum LoadEstimate {
    public struct Point: Sendable {
        public var t: Double
        public var speedMps: Double
        public var powerW: Double
        public init(t: Double, speedMps: Double, powerW: Double) { self.t = t; self.speedMps = speedMps; self.powerW = powerW }
    }

    /// Pull (N per m/s²) from 1-s readings; nil with fewer than 12 clean speed-ups or too little spread in acceleration
    public static func pull(_ pts: [Point]) -> Double? {
        var xs: [Double] = [], ys: [Double] = []
        for (a, b) in zip(pts, pts.dropFirst()) {
            let dt = b.t - a.t
            guard dt > 0.5, dt < 2 else { continue }
            // the power now drives the speed gain up to the next reading
            let v = a.speedMps
            let acc = (b.speedMps - a.speedMps) / dt
            let p = a.powerW
            guard v >= 2, v <= 8, acc >= 0.3, p > 0 else { continue }
            xs.append(acc); ys.append(p / v)
        }
        guard xs.count >= 12 else { return nil }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        guard sxx / Double(xs.count) > 0.01 else { return nil }
        let sxy = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let slope = sxy / sxx
        return slope > 0 ? slope : nil
    }

    /// Extra load as a share of the usual (0.2 = about 20 % more mass than this scooter's usual rides)
    public static func extraShare(pull: Double, usualPulls: [Double]) -> Double? {
        guard usualPulls.count >= 5, let m = EnergyHint.median(usualPulls), m > 0 else { return nil }
        return pull / m - 1
    }
}
