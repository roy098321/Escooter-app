import Foundation

// Batch 4 (owner 11 Nov, D-PR-09; B88 / B89 / B91 / B94): ONE battery number per ride. The sag-proof (smoothed) level is used by the
// live dashboard, the voice (every 10 %, arrival line, 20 / 15 / 10 %), the map's 10 % marks and the drain warning. Pure, tested on Linux.

/// "The smoothed level first reaches N": the one rule for the voice's "Battery at N percent" and the map's N% marks (B88).
/// Levels are the multiples of 10 below the start; each is reached once (a 90 ↔ 89 flicker gives one).
public struct TenPercentRule: Codable, Equatable, Sendable {
    /// The next multiple of 10 still to reach (nil before the start is known)
    public private(set) var next: Int?

    public init() {}

    /// The ride's start level: the first multiple of 10 below it is the next one to reach (90.0 → 80, 90.4 → 90)
    public mutating func start(at pct: Double) { next = (Int(pct.rounded(.up)) - 1) / 10 * 10 }

    /// After a relaunch: nothing at or above the level now is said again (B94)
    public mutating func resume(at level: Double) {
        let below = (Int(level.rounded(.up)) - 1) / 10 * 10
        next = min(next ?? below, below)
    }

    /// The levels this smoothed level has reached, highest first (each once). The voice says the last (lowest) one.
    public mutating func update(level: Double) -> [Int] {
        guard var n = next else { return [] }
        var out: [Int] = []
        while n > 0, level <= Double(n) {
            out.append(n)
            n -= 10
        }
        next = n
        return out
    }
}

/// The one battery level of a live ride, kept by the app once a second (dashboard, voice, marks). Codable so it survives a relaunch.
public struct RideBatteryLevel: Codable, Equatable, Sendable {
    /// After a relaunch the level follows the highest reading of this many seconds (a reading under load only sags lower), B94
    public static let reseedS = 30.0

    /// The engine ride this belongs to (its start time, stable across relaunches)
    public private(set) var rideKey: Double?
    public private(set) var startPct: Double?
    public private(set) var level: Double?
    private var usedWh = 0.0
    private var offset = 0.0
    private var lastT: Double?
    private var restSince: Double?
    private var moved = false
    private var usesEnergy = false
    private var tens = TenPercentRule()
    private var tenStart: Double?
    /// After a relaunch: re-seed from the live reading until this time (epoch s)
    private var reseedUntil: Double?
    private var reseedMax: Double?
    /// Relaunched with no saved state: the start is not known, the re-seeded reading stands in for it
    private var startFromReseed = false
    /// N4-7 (B87): the destination key already announced for this ride
    public var announcedKey: String?
    /// N4-10 (B89): "Arrived" was said: no more battery lines for this ride
    public var arrivedSaid = false

    public init(rideKey: Double? = nil) { self.rideKey = rideKey }

    /// The ride set off (faster than walking at least once)
    public var hasSetOff: Bool { moved }

    /// The app was relaunched mid-ride (this state was restored, or there was none): the next readings re-seed the level, and no
    /// 10 % level at or above it is said again.
    public mutating func resumed(at t: Double) {
        reseedUntil = t + Self.reseedS
        reseedMax = nil
        startFromReseed = startPct == nil
        lastT = nil
        restSince = nil
    }

    /// One reading (about once a second). Returns the 10 % levels reached now (highest first; usually none).
    @discardableResult
    public mutating func update(t: Double, livePct: Double?, powerW: Double?, currentA: Double?, speedKmh: Double?,
                                whPerPct: Double) -> [Int] {
        let dt = lastT.map { t - $0 } ?? 0
        lastT = t
        if (speedKmh ?? 0) > SagProofBattery.movingKmh { moved = true }
        let rested = currentA.map { abs($0) < SagProofBattery.restCurrentA }
            ?? powerW.map { abs($0) < Self.restPowerW && (speedKmh ?? 0) <= V09Timing.stoppedKmh } ?? false
        if rested { if restSince == nil { restSince = t } } else { restSince = nil }
        if let p = powerW {
            usesEnergy = true
            if dt > 0, dt <= SagProofBattery.maxStepS { usedWh += p * dt / 3600 }
        }
        if reseedUntil == nil, let live = livePct, startPct == nil || (!moved && (rested || currentA == nil)) {
            startPct = live
            usedWh = 0
            offset = 0
        }
        guard let s = startPct ?? livePct else { return [] }
        if startPct == nil { startPct = s }
        var l: Double
        if usesEnergy, whPerPct > 0 {
            l = s - usedWh / whPerPct + offset
            if let live = livePct, let since = restSince, t - since >= SagProofBattery.restHoldS, dt > 0 {
                offset += (live - l) * min(1, SagProofBattery.nudgePerS * min(dt, SagProofBattery.maxStepS))
                l = s - usedWh / whPerPct + offset
            }
        } else {
            l = livePct ?? level ?? s
        }
        // B94: after a relaunch the level is the live reading again (its highest in the first seconds: under load it only sags)
        if let until = reseedUntil, let live = livePct {
            let m = max(reseedMax ?? live, live)
            reseedMax = m
            offset += m - l
            l = m
            if startFromReseed { startPct = m; usedWh = 0; offset = 0 }
            if t >= until { reseedUntil = nil; reseedMax = nil }
        }
        level = l
        // the 10 % rule starts at the start level (it may still change before setting off)
        if tens.next == nil || (!moved && tenStart != s) {
            tenStart = s
            tens.start(at: s)
        }
        if reseedMax != nil { tens.resume(at: l) }
        return tens.update(level: l)
    }

    /// Without current readings: a scooter drawing under this, at a stop, counts as rested (stored rides keep power, not current)
    public static let restPowerW = 15.0

    /// The ride's end level: what the arrival line says and the ride's end (start − used agrees with it)
    public var endPct: Double? { level }
}

/// N4-12 (B91): one start, end and "used" for a stored ride. "Used" is the calibrated figure the ride page shows; the end level is the
/// start minus it, so the summary, the map legend and the list never disagree.
public struct RideBatteryEnds: Equatable, Sendable {
    public var startPct: Double?
    public var endPct: Double?
    public var usedPct: Double?

    public init(startPct: Double?, endPct: Double?, usedPct: Double?) {
        self.startPct = startPct
        self.endPct = endPct
        self.usedPct = usedPct
    }

    /// - shownUsed: the stored shown figure (CalibrationUpdater), usedPct: the ride's own figure; rested start / end; first / last reading
    public static func make(shownUsed: Double?, usedPct: Double?, startRestPct: Double?, endRestPct: Double?,
                            firstPct: Double? = nil, lastPct: Double? = nil) -> RideBatteryEnds {
        let start = startRestPct ?? firstPct
        let used = shownUsed ?? usedPct
        if let s = start, let u = used, u >= 0 { return RideBatteryEnds(startPct: s, endPct: max(0, s - u), usedPct: u) }
        let end = endRestPct ?? lastPct
        if let s = start, let e = end, s >= e { return RideBatteryEnds(startPct: s, endPct: e, usedPct: s - e) }
        return RideBatteryEnds(startPct: start, endPct: end, usedPct: used)
    }
}

/// N4-14 (B93): the arrival line is said only for a real ride (not a ride that will be discarded, not a short hop) and names the
/// destination announced at the start when the rider did not cross into a saved place.
public enum ArrivalRule {
    public static func allowed(rideKm: Double) -> Bool { RideSizeClass.of(distanceM: rideKm * 1000) == .ride }

    /// The name the arrival line uses: the place crossed into, else the destination announced at the start
    public static func name(place: String?, announced: String?) -> String? {
        if let p = place, !p.isEmpty { return p }
        if let a = announced, !a.isEmpty { return a }
        return nil
    }
}

/// N4-12 (B91): the Battery layer's legend ends are the ride's end and start levels (nil without both)
public enum BatteryLegend {
    public static func text(_ ends: RideBatteryEnds) -> (low: String, high: String)? {
        guard let s = ends.startPct, let e = ends.endPct else { return nil }
        return ("\(Int(min(s, e).rounded()))%", "\(Int(max(s, e).rounded()))%")
    }
}
