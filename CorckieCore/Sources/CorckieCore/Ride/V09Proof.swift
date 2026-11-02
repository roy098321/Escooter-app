import Foundation

// Hotfix 03 proof: every spoken line with the numbers behind it, the ride summary's said-vs-real lines, and the voice replay over
// stored rides (Developer). Pure, tested on Linux.

public struct V09SaidLine: Equatable, Sendable, Codable {
    public var line: String
    public var kind: String
    /// the number said: % for battery lines, minutes for late lines
    public var value: Int?
    public var numbers: V09Numbers

    public init(line: String, kind: String, value: Int?, numbers: V09Numbers) {
        self.line = line
        self.kind = kind
        self.value = value
        self.numbers = numbers
    }

    public init(_ m: V09Message, numbers: V09Numbers) {
        self.init(line: m.line, kind: m.kind, value: m.value, numbers: numbers)
    }
}

/// The ride summary's lines: what the voice said against what really happened (under More)
public enum V09SaidCompare {
    static func clock(_ epochS: Double, _ utcOffsetMin: Int) -> String {
        let local = Int64(epochS) + Int64(utcOffsetMin) * 60
        return DayClock.clockText(minuteOfDay: Int((((local % 86_400) + 86_400) % 86_400) / 60))
    }

    /// - realArrivalPct: the battery at the end (rested); realArrivalS: when the ride ended (epoch s)
    public static func lines(_ said: [V09SaidLine], realArrivalPct: Double?, realArrivalS: Double?, utcOffsetMin: Int) -> [String] {
        var out: [String] = []
        for s in said {
            switch s.kind {
            case "start":
                var text = "Voice: \u{201C}\(s.line)\u{201D}"
                if let at = s.numbers.arriveAtS, let r = realArrivalS {
                    text += " \u{00B7} real arrival \(clock(r, utcOffsetMin)) (said \(clock(at, utcOffsetMin)))"
                }
                out.append(text)
            case "drop", "low", "back":
                var text = "Voice: \u{201C}\(s.line)\u{201D}"
                if let real = realArrivalPct, let v = s.value {
                    text += " \u{00B7} real \(Int(real.rounded()))% (\(Int(abs(real - Double(v)).rounded())) off)"
                }
                out.append(text)
            case "late", "ontime":
                var text = "Voice: \u{201C}\(s.line)\u{201D}"
                if let at = s.numbers.arriveAtS, let r = realArrivalS {
                    let off = Int(((r - at) / 60).rounded())
                    text += " \u{00B7} real arrival \(clock(r, utcOffsetMin)) (\(off == 0 ? "on the minute" : "\(abs(off)) min \(off > 0 ? "later" : "sooner")"))"
                }
                out.append(text)
            default:
                continue
            }
        }
        return out
    }
}

// MARK: Voice replay (proof on past rides)

/// Developer → Voice replay: the new director over a stored ride, every second, with the route's OTHER rides as history.
/// Pass = no contradictions, at most 2 battery lines, the last battery line within 5 points of the real arrival %, no late line before
/// the gate.
public enum V09Replay {
    public struct Result: Equatable, Sendable {
        public var said: [V09SaidLine]
        public var realArrivalPct: Double?
        public var realArrivalS: Double?
        public var problems: [String]
        public var passed: Bool { problems.isEmpty }

        public init(said: [V09SaidLine], realArrivalPct: Double?, realArrivalS: Double?, problems: [String]) {
            self.said = said
            self.realArrivalPct = realArrivalPct
            self.realArrivalS = realArrivalS
            self.problems = problems
        }
    }

    public static let maxBatteryLines = 2
    public static let arrivalWithinPts = 5.0

    public static func run(samples: [RouteHistorySample], route: RouteFollower, whPerPct: Double, usualPctPerKm: Double? = nil,
                           placeName: String? = nil, utcOffsetMin: Int = 0) -> Result {
        let s = samples.sorted { $0.t < $1.t }
        var d = V09Director()
        var f = route
        var said: [V09SaidLine] = []
        var rideM = 0.0
        var t0: Double?
        var lastT: Double?
        var arrivedAt: Double?
        var course: Double?
        var lastPos: GeoPoint?
        for p in s {
            if let l = lastT, let v = p.speedKmh { let dt = p.t - l; if dt > 0, dt <= 5 { rideM += v / 3.6 * dt } }
            lastT = p.t
            if t0 == nil, (p.speedKmh ?? 0) > SagProofBattery.movingKmh { t0 = p.t }
            let elapsed = t0.map { max(0, p.t - $0) } ?? 0
            var along: Double?
            var remaining: Double?
            if let lat = p.lat, let lon = p.lon {
                let here = GeoPoint(lat: lat, lon: lon)
                if let a = lastPos, Geo.distanceM(a, here) >= 8 { course = bearing(a, here); lastPos = here } else if lastPos == nil { lastPos = here }
                let step = f.update(position: here, gpsFresh: true, rideDistanceM: rideM, elapsedS: elapsed)
                if !step.offPath {
                    along = step.alongM / 1000
                    remaining = step.remainingS
                    if arrivedAt == nil, step.alongM >= f.totalM - LiveScreenDriver.arrivedWithinM { arrivedAt = p.t }
                }
            }
            let input = V09Input(t: p.t, pct: p.batteryPct, tempC: p.tempC, rideKm: rideM / 1000, speedKmh: p.speedKmh, courseDeg: course,
                                 usualPctPerKm: usualPctPerKm, routeKm: f.totalM / 1000, alongKm: along, elapsedS: elapsed,
                                 remainingS: remaining, powerW: p.powerW, currentA: p.currentA, whPerPct: whPerPct,
                                 history: route.history, todayS: route.todayS, placeName: placeName, utcOffsetMin: utcOffsetMin)
            for m in d.update(input) { said.append(V09SaidLine(m, numbers: d.numbers)) }
            if arrivedAt != nil { break }
        }
        // the real arrival %: the battery after the sag, in the minute after arriving (else the last minute of the ride)
        let end = arrivedAt ?? s.last?.t
        var real: Double?
        if let e = end { real = s.filter { $0.t >= e - 5 && $0.t <= e + 60 }.compactMap(\.batteryPct).max() }
        let result = Result(said: said, realArrivalPct: real, realArrivalS: end, problems: [])
        return verdict(result, routeKm: route.totalM / 1000)
    }

    /// The pass rules
    public static func verdict(_ r: Result, routeKm: Double) -> Result {
        var out = r
        var problems: [String] = []
        let battery = r.said.filter { ["drop", "low", "back"].contains($0.kind) }
        if battery.count > maxBatteryLines { problems.append("\(battery.count) battery lines (most \(maxBatteryLines))") }
        var last: Int?
        for b in battery where b.kind != "back" {
            if let v = b.value, let l = last, v >= l { problems.append("said \(v)% after \(l)%") }
            last = b.value ?? last
        }
        if r.said.filter({ $0.kind == "back" }).count > 1 { problems.append("Back on track more than once") }
        if let lastLine = battery.last, let v = lastLine.value, let real = r.realArrivalPct, abs(Double(v) - real) > arrivalWithinPts {
            problems.append("said about \(v)%, arrived with \(Int(real.rounded()))%")
        }
        var lateLast = 0
        for l in r.said where l.kind == "late" {
            let along = l.numbers.alongKm ?? 0
            if along < max(V09Director.lateAfterKm, routeKm / 3) - 0.05 { problems.append("late line at km \(String(format: "%.1f", along)), before the gate") }
            if let v = l.value { if v < lateLast + V09Director.lateMin { problems.append("late \(v) min after \(lateLast) min") }; lateLast = v }
        }
        out.problems = problems
        return out
    }

    static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLon = (b.lon - a.lon) * .pi / 180
        let la = a.lat * .pi / 180, lb = b.lat * .pi / 180
        let y = sin(dLon) * cos(lb)
        let x = cos(la) * sin(lb) - sin(la) * cos(lb) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: Made-up rides for the lab checks (not a real place)

/// A made-up 10 km route due north and made-up rides on it, one reading a second (lab checks u186–u189; never real data)
public enum V09Lab {
    public static let km = 10.0
    public static let t0 = 1_000_000.0

    public static func point(_ m: Double) -> GeoPoint { GeoPoint(lat: 10 + m / Geo.mPerDegLat, lon: -30) }
    /// km along the made-up route of a made-up reading
    public static func km(of s: RouteHistorySample) -> Double { ((s.lat ?? 10) - 10) * Geo.mPerDegLat / 1000 }

    public static func follower(todayS: Double = 1_440, history: RouteHistory? = nil) -> RouteFollower? {
        var f = RouteFollower(destinationName: "Uni", path: stride(from: 0.0, through: km * 1000, by: 100).map { point($0) }, todayS: todayS)
        f?.history = history
        return f
    }

    /// - pctPerKm: true use per km; sagKm: a hill where the scooter's % reads 8 low for 40 s; stopAtKm: a 60 s red light;
    ///   slowFromKm: from there 17 km/h
    public static func ride(pctPerKm: @escaping (Double) -> Double = { _ in 2 }, sagKm: Double? = nil, stopAtKm: Double? = nil,
                            slowFromKm: Double? = nil, startPct: Double = 90, whPerPct: Double = 8.1) -> [RouteHistorySample] {
        var out: [RouteHistorySample] = []
        var t = 0.0, d = 0.0, used = 0.0, stopLeft = 0.0
        var stopDone = stopAtKm == nil
        func add(_ v: Double, _ w: Double) {
            var sag = 0.0
            if let h = sagKm, d / 1000 >= h, d / 1000 < h + 0.28 { sag = 8 }
            out.append(RouteHistorySample(t: t0 + t, lat: point(d).lat, lon: -30, speedKmh: v, batteryPct: (startPct - used - sag).rounded(),
                                          powerW: w, currentA: w / 50))
            t += 1
        }
        for _ in 0..<10 { add(0, 0) }
        while d < km * 1000 {
            if stopLeft > 0 { add(0, 0); stopLeft -= 1; continue }
            if !stopDone, let s = stopAtKm, d >= s * 1000 { stopDone = true; stopLeft = 60; continue }
            let v = (slowFromKm.map { d / 1000 >= $0 } ?? false) ? 17.0 : 25.0
            let step = min(v / 3.6, km * 1000 - d)
            let p = pctPerKm(d / 1000) * step / 1000
            used += p
            d += step
            add(v, p * whPerPct * 3600)
        }
        for _ in 0..<60 { add(0, 0) }
        return out
    }

    /// Three past rides at 2 %/km in 24 min
    public static func history() -> RouteHistory? {
        guard let f = follower(), let one = RouteRideProfile.make(samples: ride(), route: f, whPerPct: 8.1) else { return nil }
        return RouteHistory(rides: [one, one, one], routeKm: km)
    }
}
