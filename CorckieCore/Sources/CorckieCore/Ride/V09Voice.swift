import Foundation

/// V09 voice energy updates (owner 27–28 Oct, batch 102, NEXT_BUILD "V09"): what the rider hears to adjust the ride and plan time.
/// URGENT (said now): sharp drop in the estimated arrival %, engine overheating (93 °C), engine hot (85 °C), point of no return (before
/// passing it, tight trips only), recording problem, every 10 % of battery. CAN WAIT (best moment): using more than usual, arriving under
/// 20 %, running late, low-battery power limit coming: (1) stopped now; (2) a usual stop within ~1 km on a known route → wait for it;
/// (3) a straight steady stretch; (4) otherwise after at most ~2 min / 1 km. Arrival: "Arrived at Uni, battery at 58 percent." on
/// crossing into the place (or at ride end without a saved place), right away. Using less than usual = silent. Universal: names come from
/// the rider's own places. Pure, so it is tested on Linux.
public enum V09Message: Equatable, Sendable {
    case usingMore(pctPerKm: Double, aboveUsualPct: Int)
    case everyTen(pct: Int)
    case arrivingLow(pct: Int)
    case sharpDrop(pct: Int)
    case runningLate(minutes: Int)
    case pointOfNoReturn(metres: Int)
    case powerLimitComing(pct: Int)
    case engineHot(c: Int)
    case engineOverheating(c: Int)
    case recordingProblem
    case arrived(place: String?, pct: Int)

    public var urgent: Bool {
        switch self {
        case .usingMore, .arrivingLow, .runningLate, .powerLimitComing: return false
        default: return true
        }
    }

    /// The sentence (numbers as words, like the battery lines)
    public var line: String {
        let w = SpokenNumber.words
        switch self {
        case let .usingMore(rate, above):
            let tenths = Int((rate * 10).rounded())
            return "Using \(w(tenths / 10)) point \(w(tenths % 10)) percent per kilometre, \(w(above)) percent above usual."
        case let .everyTen(p): return "Battery at \(w(p)) percent."
        case let .arrivingLow(p): return "Arriving with about \(w(p)) percent."
        case let .sharpDrop(p): return "Arrival battery dropped to \(w(p)) percent."
        case let .runningLate(m): return "Arriving \(w(m)) \(m == 1 ? "minute" : "minutes") later than usual."
        case let .pointOfNoReturn(m): return "Point of no return in \(w(max(1, m / 100))) hundred metres."
        case let .powerLimitComing(p): return "Power limit coming at \(w(p)) percent."
        case let .engineHot(c): return "Engine hot, \(w(c)) degrees."
        case let .engineOverheating(c): return "Engine overheating, \(w(c)) degrees."
        case .recordingProblem: return "Recording problem. Check the app when you stop."
        case let .arrived(place, p):
            if let place, !place.isEmpty { return "Arrived at \(place), battery at \(w(p)) percent." }
            return "Arrived, battery at \(w(p)) percent."
        }
    }

    /// One of each, for the Developer "play every message" button and the ride screen preview (made-up numbers, no real place)
    public static let samples: [V09Message] = [
        .usingMore(pctPerKm: 2.6, aboveUsualPct: 15), .everyTen(pct: 60), .arrivingLow(pct: 14), .sharpDrop(pct: 9), .runningLate(minutes: 8),
        .pointOfNoReturn(metres: 300), .powerLimitComing(pct: 18), .engineHot(c: 86), .engineOverheating(c: 94), .recordingProblem,
        .arrived(place: "Uni", pct: 58), .arrived(place: nil, pct: 41)
    ]
}

/// What V09 needs each second of a ride
public struct V09Input: Sendable {
    public var t: Double
    public var pct: Double?
    public var tempC: Double?
    public var rideKm: Double
    public var speedKmh: Double?
    /// The heading now, degrees (nil without GPS course)
    public var courseDeg: Double?
    /// The usual battery %/km (followed route, else recent rides)
    public var usualPctPerKm: Double?
    public var reservePct: Double
    /// Followed route: km of it and done so far; nil = no route
    public var routeKm: Double?
    public var alongKm: Double?
    /// The route's usual ride time and this ride's time so far + the time still to ride (s)
    public var usualTripS: Double?
    public var elapsedS: Double
    public var remainingS: Double?
    /// LBP: the learned limit (nil = not learned)
    public var powerLimitPct: Int?
    /// The phone took over / the scooter's readings are not trusted / disconnected
    public var recordingProblem: Bool
    /// A usual stop of this route this far ahead (nil = none known)
    public var usualStopAheadM: Double?

    public init(t: Double, pct: Double?, tempC: Double? = nil, rideKm: Double, speedKmh: Double? = nil, courseDeg: Double? = nil,
                usualPctPerKm: Double? = nil, reservePct: Double = T.t80ReserveDefaultPct, routeKm: Double? = nil, alongKm: Double? = nil,
                usualTripS: Double? = nil, elapsedS: Double = 0, remainingS: Double? = nil, powerLimitPct: Int? = nil,
                recordingProblem: Bool = false, usualStopAheadM: Double? = nil) {
        self.t = t
        self.pct = pct
        self.tempC = tempC
        self.rideKm = rideKm
        self.speedKmh = speedKmh
        self.courseDeg = courseDeg
        self.usualPctPerKm = usualPctPerKm
        self.reservePct = reservePct
        self.routeKm = routeKm
        self.alongKm = alongKm
        self.usualTripS = usualTripS
        self.elapsedS = elapsedS
        self.remainingS = remainingS
        self.powerLimitPct = powerLimitPct
        self.recordingProblem = recordingProblem
        self.usualStopAheadM = usualStopAheadM
    }
}

/// Engine temperature (owner 27 Oct, data-based): "Engine hot" at 85 °C, "Engine overheating" at 93 °C; a reading must hold ~20 s
/// (3 readings) before it counts; each at most once, re-armed only after cooling 10 °C below its level AND at least 10 min later.
public struct EngineTempTracker: Equatable, Sendable {
    public static let hotC = 85.0
    public static let overheatC = 93.0
    public static let holdS = 20.0
    public static let rearmBelowC = 10.0
    public static let rearmAfterS = 600.0

    private var aboveSince: [Double: Double] = [:]
    private var saidAt: [Double: Double] = [:]
    private var armed: [Double: Bool] = [hotC: true, overheatC: true]

    public init() {}

    public mutating func update(tempC: Double?, at t: Double) -> V09Message? {
        guard let c = tempC else { return nil }
        var out: V09Message?
        for level in [Self.overheatC, Self.hotC] {
            if c < level - Self.rearmBelowC, let said = saidAt[level], t - said >= Self.rearmAfterS { armed[level] = true }
            if c >= level {
                if aboveSince[level] == nil { aboveSince[level] = t }
                if armed[level] == true, let since = aboveSince[level], t - since >= Self.holdS, out == nil {
                    armed[level] = false
                    saidAt[level] = t
                    if level == Self.overheatC { armed[Self.hotC] = false; saidAt[Self.hotC] = t }   // overheating covers hot
                    out = level == Self.overheatC ? .engineOverheating(c: Int(c.rounded())) : .engineHot(c: Int(c.rounded()))
                }
            } else {
                aboveSince[level] = nil
            }
        }
        return out
    }
}

/// When a can-wait message is said
public enum V09Timing {
    public static let stoppedKmh = 2.0
    public static let stopAheadM = 1_000.0
    public static let maxWaitS = 120.0
    public static let maxWaitKm = 1.0
    /// Steady: speed within this of the last 10 s and the heading within `straightDeg`
    public static let steadyKmh = 2.5
    public static let straightDeg = 10.0

    public enum Moment: Equatable, Sendable { case stopped, steadyStraight, waitedLongEnough }

    /// nil = keep waiting
    public static func moment(queuedAt t0: Double, queuedKm k0: Double, now t: Double, rideKm: Double, speedKmh: Double?,
                              steadyStraight: Bool, usualStopAheadM: Double?) -> Moment? {
        if (speedKmh ?? 0) <= stoppedKmh { return .stopped }
        let waitedOut = t - t0 >= maxWaitS || rideKm - k0 >= maxWaitKm
        if waitedOut { return .waitedLongEnough }
        if let ahead = usualStopAheadM, ahead <= stopAheadM { return nil }   // a usual stop is coming: wait for it
        return steadyStraight ? .steadyStraight : nil
    }

    /// Steady and straight over the recent seconds (speed and heading)
    public static func steadyStraight(speeds: [Double], courses: [Double]) -> Bool {
        guard speeds.count >= 5, let lo = speeds.min(), let hi = speeds.max(), hi - lo <= steadyKmh * 2, lo > stoppedKmh else { return false }
        guard courses.count >= 5 else { return false }
        let base = courses[0]
        return courses.allSatisfy { abs(angle($0 - base)) <= straightDeg }
    }

    static func angle(_ d: Double) -> Double {
        var a = d.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        return a
    }
}

/// Runs every V09 rule for one ride. Urgent messages come out at once; can-wait ones are queued and come out at the right moment.
public struct V09Director: Sendable {
    /// Using more than usual: after 3 km, 10 % above (again at +10 more points)
    public static let usingMoreAfterKm = 3.0
    public static let usingMoreShare = 0.10
    /// Arriving under 20 %
    public static let arrivingLowPct = 20.0
    /// Sharp drop: the estimated arrival % falls this much within `sharpWindowS`
    public static let sharpDropPts = 5.0
    public static let sharpWindowS = 120.0
    /// Running late: 5 min over the usual time (again every 5 more)
    public static let lateMin = 5
    /// Point of no return: said this far before it, on tight trips (arrival estimate under 20 %)
    public static let pnrBeforeM = 300.0
    /// Power limit: said this many % before the learned limit
    public static let powerLimitAheadPct = 3

    private var engine = EngineTempTracker()
    private var startPct: Double?
    private var nextTen: Int?
    private var usingMoreSaid: Int?
    private var arrivingLowSaid = false
    private var arrivalHistory: [(t: Double, pct: Double)] = []
    private var sharpSaidAt: Double?
    private var lateSaid = 0
    private var pnrSaid = false
    private var powerLimitSaid = false
    private var problemSaid = false
    private var problemClearSince: Double?
    private var queue: [(msg: V09Message, t: Double, km: Double)] = []
    private var speeds: [Double] = []
    private var courses: [Double] = []

    public init() {}

    /// The estimated battery % at arrival (honest, this ride's %/km once known, else usual), nil without a route
    public static func arrivalPct(pct: Double, rideKm: Double, startPct: Double, routeKm: Double?, alongKm: Double?, usualPctPerKm: Double?) -> Double? {
        guard let routeKm, let alongKm else { return nil }
        let left = max(0, routeKm - alongKm)
        let rate = rideKm >= 1 && startPct > pct ? (startPct - pct) / rideKm : usualPctPerKm
        guard let r = rate, r > 0 else { return nil }
        return pct - left * r
    }

    /// Where along the route turning back still gets home with the reserve: pct − (x − along)·r = reserve + x·r
    public static func pointOfNoReturnKm(pct: Double, alongKm: Double, ratePctPerKm: Double, reservePct: Double) -> Double? {
        guard ratePctPerKm > 0 else { return nil }
        return (pct + alongKm * ratePctPerKm - reservePct) / (2 * ratePctPerKm)
    }

    public mutating func update(_ i: V09Input) -> [V09Message] {
        var urgent: [V09Message] = []
        if let s = i.speedKmh { speeds.append(s); if speeds.count > 10 { speeds.removeFirst() } }
        if let c = i.courseDeg { courses.append(c); if courses.count > 10 { courses.removeFirst() } }

        if let m = engine.update(tempC: i.tempC, at: i.t) { urgent.append(m) }
        // recording problem: once per problem, again only after 2 min without one
        if i.recordingProblem {
            problemClearSince = nil
            if !problemSaid { problemSaid = true; urgent.append(.recordingProblem) }
        } else if problemSaid {
            if problemClearSince == nil { problemClearSince = i.t }
            if let s = problemClearSince, i.t - s >= 120 { problemSaid = false }
        }

        if let pct = i.pct {
            // every 10 % (30 % and up; 20 / 15 / 10 keep their own range lines): said when the battery reaches the level
            if startPct == nil { startPct = pct; nextTen = (Int(pct.rounded(.up)) - 1) / 10 * 10 }
            if let n = nextTen, pct <= Double(n) {
                let reached = Int((pct / 10).rounded(.up)) * 10
                nextTen = reached - 10
                if reached >= 30 { urgent.append(.everyTen(pct: reached)) }
            }
            // using more than usual
            if i.rideKm >= Self.usingMoreAfterKm, let usual = i.usualPctPerKm, usual > 0, let s = startPct, s > pct {
                let rate = (s - pct) / i.rideKm
                let above = Int(((rate / usual - 1) * 100).rounded())
                if Double(above) >= Self.usingMoreShare * 100, above >= (usingMoreSaid ?? 0) + 10 {
                    usingMoreSaid = above
                    enqueue(.usingMore(pctPerKm: rate, aboveUsualPct: above), i)
                }
            }
            if let arrive = Self.arrivalPct(pct: pct, rideKm: i.rideKm, startPct: startPct ?? pct, routeKm: i.routeKm, alongKm: i.alongKm,
                                            usualPctPerKm: i.usualPctPerKm) {
                // arriving under 20 %
                if arrive < Self.arrivingLowPct, !arrivingLowSaid, i.rideKm >= 1 {
                    arrivingLowSaid = true
                    enqueue(.arrivingLow(pct: max(0, Int(arrive.rounded()))), i)
                }
                // sharp, unexpected drop of the arrival estimate: say it now
                arrivalHistory.append((i.t, arrive))
                arrivalHistory.removeAll { i.t - $0.t > Self.sharpWindowS }
                if let top = arrivalHistory.map(\.pct).max(), top - arrive >= Self.sharpDropPts,
                   i.t - (sharpSaidAt ?? -1e9) >= Self.sharpWindowS, i.rideKm >= 1 {
                    sharpSaidAt = i.t
                    arrivalHistory = [(i.t, arrive)]
                    urgent.append(.sharpDrop(pct: max(0, Int(arrive.rounded()))))
                }
                // point of no return (tight trips only), just before it
                if !pnrSaid, arrive < Self.arrivingLowPct, let along = i.alongKm, let s = startPct, i.rideKm >= 1, s > pct,
                   let pnr = Self.pointOfNoReturnKm(pct: pct, alongKm: along, ratePctPerKm: (s - pct) / i.rideKm, reservePct: i.reservePct) {
                    let ahead = (pnr - along) * 1000
                    if ahead > 0 && ahead <= Self.pnrBeforeM {
                        pnrSaid = true
                        urgent.append(.pointOfNoReturn(metres: Int((ahead / 100).rounded(.up)) * 100))
                    }
                }
            }
            // power limit coming
            if let limit = i.powerLimitPct, !powerLimitSaid, pct <= Double(limit + Self.powerLimitAheadPct), pct > Double(limit) {
                powerLimitSaid = true
                enqueue(.powerLimitComing(pct: limit), i)
            }
        }
        // running late
        if let usual = i.usualTripS, let left = i.remainingS {
            let late = Int(((i.elapsedS + left - usual) / 60).rounded())
            if late >= Self.lateMin, late >= lateSaid + Self.lateMin {
                lateSaid = late
                enqueue(.runningLate(minutes: late), i)
            }
        }
        // the queue: at the best moment
        var waiting: [V09Message] = []
        if !queue.isEmpty {
            let steady = V09Timing.steadyStraight(speeds: speeds, courses: courses)
            var keep: [(msg: V09Message, t: Double, km: Double)] = []
            for q in queue {
                if V09Timing.moment(queuedAt: q.t, queuedKm: q.km, now: i.t, rideKm: i.rideKm, speedKmh: i.speedKmh, steadyStraight: steady,
                                    usualStopAheadM: i.usualStopAheadM) != nil {
                    waiting.append(q.msg)
                } else {
                    keep.append(q)
                }
            }
            queue = keep
        }
        return urgent + waiting
    }

    private mutating func enqueue(_ m: V09Message, _ i: V09Input) {
        queue.removeAll { Self.sameKind($0.msg, m) }
        queue.append((m, i.t, i.rideKm))
    }

    private static func sameKind(_ a: V09Message, _ b: V09Message) -> Bool {
        switch (a, b) {
        case (.usingMore, .usingMore), (.arrivingLow, .arrivingLow), (.runningLate, .runningLate), (.powerLimitComing, .powerLimitComing): return true
        default: return false
        }
    }

    /// Messages still waiting for their moment
    public var waitingCount: Int { queue.count }
}

/// Arrival line: once per arrival (crossing into the place); without a saved place at the ride's end
public struct ArrivalLineTracker: Equatable, Sendable {
    private var said = false
    public init() {}
    public mutating func reset() { said = false }

    /// The rider crossed into the destination place (`arrived` turned true)
    public mutating func arrived(place: String?, pct: Double?) -> V09Message? {
        guard !said, let p = pct else { return nil }
        said = true
        return .arrived(place: place, pct: Int(p.rounded()))
    }

    /// The ride ended: "Arrived, battery at X percent" only when no place arrival was said
    public mutating func rideEnded(pct: Double?) -> V09Message? {
        guard !said, let p = pct else { return nil }
        said = true
        return .arrived(place: nil, pct: Int(p.rounded()))
    }
}
