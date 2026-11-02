import Foundation

// Hotfix 03 (owner, Mon 2 Nov, B69 / B70): what the voice's numbers stand on. Rule for every voice number: the right input, compared
// point by point with the rider's own rides on this route, said only when sure, never contradicted later. Pure, tested on Linux.

// MARK: Sag-proof battery level (H1 input)

/// The battery level the voice uses: the rested start % minus the energy used (V × I) ÷ Wh per 1 % (CalibrationUpdater). Under load
/// the scooter's own % sags up to ~10 points (T41) and comes back after the hill; energy does not. The level is nudged towards the
/// scooter's % only while the current is about 0 (stopped or coasting) for a while, when that % is a rested one. A scooter without power
/// readings: the scooter's % as it is (the old behaviour).
public struct SagProofBattery: Equatable, Sendable {
    /// |current| under this counts as rested (no load)
    public static let restCurrentA = 0.5
    /// rested this long before the scooter's % is trusted
    public static let restHoldS = 10.0
    /// share of the gap to the rested % closed per second while rested
    public static let nudgePerS = 0.02
    /// a longer step between readings adds no energy (a gap is never a guess). B71 (hotfix 04): ONE limit for the live readings
    /// (about 1 s apart), the stored ride rows (5.1–5.3 s apart, RideRecorderCore.sampleIntervalS 5) and the voice replay; it was 5 s,
    /// which dropped every stored step, so past rides used 0 % and the arrival battery said the battery now.
    public static let maxStepS = RideMetrics.defaultMaxStepS
    /// faster than this = the ride has set off (the start % is fixed from then on)
    public static let movingKmh = 3.0

    public private(set) var startPct: Double?
    public private(set) var level: Double?
    public private(set) var usesEnergy = false
    public private(set) var usedWh = 0.0
    private var offset = 0.0
    private var lastT: Double?
    private var restSince: Double?
    private var moved = false

    public init() {}

    @discardableResult
    public mutating func update(t: Double, livePct: Double?, powerW: Double?, currentA: Double?, speedKmh: Double?,
                                whPerPct: Double) -> Double? {
        let dt = lastT.map { t - $0 } ?? 0
        lastT = t
        if (speedKmh ?? 0) > Self.movingKmh { moved = true }
        let rested = currentA.map { abs($0) < Self.restCurrentA } ?? false
        if rested { if restSince == nil { restSince = t } } else { restSince = nil }
        if let p = powerW {
            usesEnergy = true
            if dt > 0, dt <= Self.maxStepS { usedWh += p * dt / 3600 }
        }
        // the rested start: the newest reading before setting off (at rest, or a scooter without current readings)
        if let live = livePct, startPct == nil || (!moved && (rested || currentA == nil)) {
            startPct = live
            usedWh = 0
            offset = 0
        }
        guard let s = startPct else { return nil }
        guard usesEnergy, whPerPct > 0 else {
            if let live = livePct { level = live }
            return level
        }
        var l = s - usedWh / whPerPct + offset
        if let live = livePct, let since = restSince, t - since >= Self.restHoldS, dt > 0 {
            offset += (live - l) * min(1, Self.nudgePerS * min(dt, Self.maxStepS))
            l = s - usedWh / whPerPct + offset
        }
        level = l
        return l
    }
}

// MARK: Route history (point by point)

/// One reading of a stored ride, as the history and the voice replay need it
public struct RouteHistorySample: Equatable, Sendable {
    /// epoch seconds
    public var t: Double
    public var lat: Double?
    public var lon: Double?
    public var speedKmh: Double?
    public var batteryPct: Double?
    public var powerW: Double?
    public var currentA: Double?
    public var tempC: Double?

    public init(t: Double, lat: Double? = nil, lon: Double? = nil, speedKmh: Double? = nil, batteryPct: Double? = nil,
                powerW: Double? = nil, currentA: Double? = nil, tempC: Double? = nil) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.speedKmh = speedKmh
        self.batteryPct = batteryPct
        self.powerW = powerW
        self.currentA = currentA
        self.tempC = tempC
    }
}

/// One past ride along the route, a point about every 100 m: km along the route, seconds since setting off (its stops inside),
/// battery % used so far (sag-proof)
public struct RouteRideProfile: Equatable, Sendable {
    public var alongKm: [Double]
    public var elapsedS: [Double]
    public var usedPct: [Double]

    public init(alongKm: [Double], elapsedS: [Double], usedPct: [Double]) {
        self.alongKm = alongKm
        self.elapsedS = elapsedS
        self.usedPct = usedPct
    }

    public func elapsedS(atKm km: Double) -> Double? { Self.value(alongKm, elapsedS, km) }
    public func usedPct(atKm km: Double) -> Double? { Self.value(alongKm, usedPct, km) }

    /// Linear between points; from 0 before the first point; the ride's own average rate past its last point
    static func value(_ xs: [Double], _ vs: [Double], _ x: Double) -> Double? {
        guard let first = xs.first, let lastX = xs.last, let lastV = vs.last, xs.count == vs.count else { return nil }
        if x <= first { return first > 0 ? vs[0] * max(0, x) / first : vs[0] }
        if x >= lastX { return lastX > 0 ? lastV + lastV / lastX * (x - lastX) : lastV }
        for i in 1..<xs.count where xs[i] >= x {
            let a = xs[i - 1], b = xs[i]
            let f = b > a ? (x - a) / (b - a) : 0
            return vs[i - 1] + (vs[i] - vs[i - 1]) * f
        }
        return lastV
    }

    /// The point-by-point profile of one stored ride on `route` (nil: it did not ride the route from its start to its end).
    /// Battery used = energy ÷ Wh per 1 % when the ride has power readings, else the battery % with the sag taken out
    /// (the highest reading of the next minute: the % after the hill).
    public static func make(samples: [RouteHistorySample], route: RouteFollower, whPerPct: Double,
                            maxStepS: Double = SagProofBattery.maxStepS) -> RouteRideProfile? {
        makeChecked(samples: samples, route: route, whPerPct: whPerPct, maxStepS: maxStepS).profile
    }

    /// B71 sanity guard: a past ride whose profile uses under this over the route while its battery reading fell by this or more is
    /// left out of the history (a broken profile would make the arrival battery say the battery now)
    public static let implausibleUsedPct = 1.0
    public static let implausibleFallPct = 3.0

    /// `make`, and why a ride was left out (nil = kept, or simply not a ride of this route)
    public static func makeChecked(samples: [RouteHistorySample], route: RouteFollower, whPerPct: Double,
                                   maxStepS: Double = SagProofBattery.maxStepS) -> (profile: RouteRideProfile?, leftOut: String?) {
        guard let p = build(samples: samples, route: route, whPerPct: whPerPct, maxStepS: maxStepS) else { return (nil, nil) }
        let used = p.usedPct.max() ?? 0
        if used < implausibleUsedPct, let fall = batteryFall(samples), fall >= implausibleFallPct {
            return (nil, "left out: uses \(String(format: "%.1f", used)) % over the route while its battery fell \(Int(fall.rounded())) %")
        }
        return (p, nil)
    }

    /// The battery reading's fall over a stored ride: the rested start (median before setting off, else the first reading) minus the
    /// highest reading of its last minute (rested again)
    static func batteryFall(_ samples: [RouteHistorySample]) -> Double? {
        let s = samples.sorted { $0.t < $1.t }
        guard let lastT = s.last?.t else { return nil }
        let t0 = s.first(where: { ($0.speedKmh ?? 0) > SagProofBattery.movingKmh })?.t ?? s[0].t
        guard let start = Geo.median(s.filter { $0.t <= t0 }.compactMap(\.batteryPct)) ?? s.compactMap(\.batteryPct).first,
              let end = s.filter({ $0.t >= lastT - 60 }).compactMap(\.batteryPct).max() else { return nil }
        return start - end
    }

    static func build(samples: [RouteHistorySample], route: RouteFollower, whPerPct: Double, maxStepS: Double) -> RouteRideProfile? {
        let s = samples.sorted { $0.t < $1.t }
        guard let t0 = s.first(where: { ($0.speedKmh ?? 0) > SagProofBattery.movingKmh })?.t else { return nil }
        var used = [Double](repeating: 0, count: s.count)
        let withPower = s.filter { $0.powerW != nil }.count
        if whPerPct > 0, withPower * 2 >= s.count, withPower > 0 {
            var wh = 0.0
            for i in s.indices {
                if i > 0, let p = s[i].powerW ?? s[i - 1].powerW {
                    let dt = s[i].t - s[i - 1].t
                    if dt > 0, dt <= maxStepS { wh += p * dt / 3600 }
                }
                used[i] = max(0, wh / whPerPct)
            }
        } else {
            let before = s.filter { $0.t <= t0 }.compactMap(\.batteryPct)
            guard let start = Geo.median(before) ?? s.compactMap(\.batteryPct).first else { return nil }
            var top = 0.0
            for i in s.indices {
                // the highest reading in the next 60 s
                var best: Double?
                var k = i
                while k < s.count, s[k].t - s[i].t <= 60 {
                    if let p = s[k].batteryPct { best = max(best ?? p, p) }
                    k += 1
                }
                if let b = best { top = max(top, start - b) }
                used[i] = max(0, top)
            }
        }
        var f = route
        f.history = nil
        var along: [Double] = []
        var el: [Double] = []
        var us: [Double] = []
        for i in s.indices where s[i].t >= t0 {
            guard let lat = s[i].lat, let lon = s[i].lon else { continue }
            let step = f.update(position: GeoPoint(lat: lat, lon: lon), gpsFresh: true, rideDistanceM: nil, elapsedS: s[i].t - t0)
            guard !step.offPath else { continue }
            let km = step.alongM / 1000
            if along.isEmpty || km >= (along.last ?? 0) + 0.1 {
                along.append(km)
                el.append(s[i].t - t0)
                us.append(used[i])
            }
        }
        let routeKm = route.totalM / 1000
        guard along.count >= 3, let first = along.first, let last = along.last,
              first <= routeKm * 0.1 + 0.2, last >= routeKm * 0.9 else { return nil }
        return RouteRideProfile(alongKm: along, elapsedS: el, usedPct: us)
    }
}

/// The route's past rides, point by point (medians), and today's estimate spread along it in the same shape
public struct RouteHistory: Equatable, Sendable {
    public var rides: [RouteRideProfile]
    public var routeKm: Double

    public init(rides: [RouteRideProfile], routeKm: Double) {
        self.rides = rides
        self.routeKm = routeKm
    }

    public var isUsable: Bool { !rides.isEmpty && routeKm > 0 }

    public func usualElapsedS(atKm km: Double) -> Double? { Geo.median(rides.compactMap { $0.elapsedS(atKm: km) }) }
    public func usualUsedPct(atKm km: Double) -> Double? { Geo.median(rides.compactMap { $0.usedPct(atKm: km) }) }
    public var usualTotalS: Double? { usualElapsedS(atKm: routeKm) }
    public var usualTotalUsedPct: Double? { usualUsedPct(atKm: routeKm) }

    /// H2: the time today's estimate gives for reaching `km` (the usual shape, usual stops inside, scaled to today's total)
    public func todayElapsedS(atKm km: Double, todayS: Double) -> Double {
        let x = min(max(0, km), routeKm)
        guard let u = usualElapsedS(atKm: x), let total = usualTotalS, total > 0 else { return todayS * (routeKm > 0 ? x / routeKm : 0) }
        return min(todayS, u / total * todayS)
    }

    public func todayRemainingS(atKm km: Double, todayS: Double) -> Double { max(0, todayS - todayElapsedS(atKm: km, todayS: todayS)) }

    /// Share of the past rides that were at `km` sooner than `elapsedS` (0.8 = slower than 80 % of them)
    public func shareFaster(elapsedS: Double, atKm km: Double) -> Double? {
        let times = rides.compactMap { $0.elapsedS(atKm: km) }
        guard !times.isEmpty else { return nil }
        return Double(times.filter { $0 < elapsedS }.count) / Double(times.count)
    }
}
