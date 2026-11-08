import Foundation

/// V09 voice energy updates (owner 27–28 Oct, batch 102, NEXT_BUILD "V09"): what the rider hears to adjust the ride and plan time.
/// URGENT (said now): the arrival battery got worse, engine overheating (93 °C), engine hot (85 °C), point of no return (before
/// passing it, tight trips only), recording problem, every 10 % of battery, the start line. CAN WAIT (best moment): using more than
/// usual, arriving under 20 %, running late, back on track / on time, low-battery power limit coming: (1) stopped now; (2) a usual stop
/// within ~1 km on a known route → wait for it; (3) a straight steady stretch; (4) otherwise after at most ~2 min / 1 km. Arrival:
/// "Arrived at Uni, battery at 58 percent." on crossing into the place (or at ride end without a saved place), right away.
/// Hotfix 03 (owner 2 Nov, B69 / B70): every number stands on the sag-proof battery level and the route's past rides point by point,
/// is said only when the estimate is stable, and is never contradicted later (see V09Trust.swift). Using less than usual = silent.
/// Universal: names come from the rider's own places. Pure, so it is tested on Linux.
public enum V09Message: Equatable, Sendable {
    case usingMore(pctPerKm: Double, aboveUsualPct: Int)
    case everyTen(pct: Int)
    case arrivingLow(pct: Int)
    /// the arrival estimate got worse (rounded to 5)
    case sharpDrop(pct: Int)
    /// once, after a drop line, when the estimate is 10 points better again
    case backOnTrack(pct: Int)
    /// late vs today's estimate, and the arrival time it gives ("9:02")
    case runningLate(minutes: Int, arriveAt: String)
    case backOnTime
    case pointOfNoReturn(metres: Int)
    case powerLimitComing(pct: Int)
    case engineHot(c: Int)
    case engineOverheating(c: Int)
    case recordingProblem
    case arrived(place: String?, pct: Int)
    /// H3: "Riding to Uni, arriving at 8:56, battery at 98 percent."
    case startLine(place: String, arriveAt: String, pct: Int)

    public var urgent: Bool {
        switch self {
        case .usingMore, .arrivingLow, .runningLate, .powerLimitComing, .backOnTrack, .backOnTime: return false
        default: return true
        }
    }

    /// Short name for the line log and the replay
    public var kind: String {
        switch self {
        case .usingMore: return "more"
        case .everyTen: return "ten"
        case .arrivingLow: return "low"
        case .sharpDrop: return "drop"
        case .backOnTrack: return "back"
        case .runningLate: return "late"
        case .backOnTime: return "ontime"
        case .pointOfNoReturn: return "pnr"
        case .powerLimitComing: return "limit"
        case .engineHot: return "hot"
        case .engineOverheating: return "overheat"
        case .recordingProblem: return "problem"
        case .arrived: return "arrived"
        case .startLine: return "start"
        }
    }

    /// The number said (%, minutes, °C, m), nil without one
    public var value: Int? {
        switch self {
        case let .usingMore(_, a): return a
        case let .everyTen(p), let .arrivingLow(p), let .sharpDrop(p), let .backOnTrack(p), let .powerLimitComing(p): return p
        case let .runningLate(m, _): return m
        case let .pointOfNoReturn(m): return m
        case let .engineHot(c), let .engineOverheating(c): return c
        case let .arrived(_, p): return p
        case let .startLine(_, _, p): return p
        case .backOnTime, .recordingProblem: return nil
        }
    }

    /// The sentence (numbers as words, like the battery lines; clock times as "9:02")
    public var line: String {
        let w = SpokenNumber.words
        switch self {
        case let .usingMore(rate, above):
            let tenths = Int((rate * 10).rounded())
            return "Using \(w(tenths / 10)) point \(w(tenths % 10)) percent per kilometre, \(w(above)) percent above usual."
        case let .everyTen(p): return "Battery at \(w(p)) percent."
        case let .arrivingLow(p): return "Arriving with about \(w(p)) percent."
        case let .sharpDrop(p): return "Arrival battery now about \(w(p)) percent."
        case let .backOnTrack(p): return "Back on track, about \(w(p)) percent."
        case let .runningLate(m, at): return "Running \(w(m)) \(m == 1 ? "minute" : "minutes") late, arriving at \(at)."
        case .backOnTime: return "Back on time."
        case let .pointOfNoReturn(m): return "Point of no return in \(w(max(1, m / 100))) hundred metres."
        case let .powerLimitComing(p): return "Power limit coming at \(w(p)) percent."
        case let .engineHot(c): return "Engine hot, \(w(c)) degrees."
        case let .engineOverheating(c): return "Engine overheating, \(w(c)) degrees."
        case .recordingProblem: return "Recording problem. Check the app when you stop."
        case let .arrived(place, p):
            if let place, !place.isEmpty { return "Arrived at \(place), battery at \(w(p)) percent." }
            return "Arrived, battery at \(w(p)) percent."
        case let .startLine(place, at, p): return "Riding to \(place), arriving at \(at), battery at \(w(p)) percent."
        }
    }

    /// One of each, for the Developer "play every message" button and the ride screen preview (made-up numbers, no real place)
    public static let samples: [V09Message] = [
        .startLine(place: "Uni", arriveAt: "8:56", pct: 98),
        .usingMore(pctPerKm: 2.6, aboveUsualPct: 15), .everyTen(pct: 60), .arrivingLow(pct: 15), .sharpDrop(pct: 40), .backOnTrack(pct: 50),
        .runningLate(minutes: 6, arriveAt: "9:02"), .backOnTime,
        .pointOfNoReturn(metres: 300), .powerLimitComing(pct: 18), .engineHot(c: 86), .engineOverheating(c: 94), .recordingProblem,
        .arrived(place: "Uni", pct: 58), .arrived(place: nil, pct: 41)
    ]

    /// Battery numbers are said rounded to 5 ("about 40 percent")
    public static func round5(_ x: Double) -> Int { max(0, Int((x / 5).rounded()) * 5) }

    /// "9:02" for an epoch time
    public static func clock(epochS: Double, utcOffsetMin: Int) -> String {
        let local = Int64(epochS) + Int64(utcOffsetMin) * 60
        return DayClock.clockText(minuteOfDay: Int((((local % 86_400) + 86_400) % 86_400) / 60))
    }
}

/// The numbers behind the voice at one moment (logged with every spoken line)
public struct V09Numbers: Equatable, Sendable, Codable {
    /// epoch seconds
    public var t: Double = 0
    public var rideKm: Double = 0
    public var alongKm: Double?
    public var routeKm: Double?
    /// the scooter's own % and the sag-proof level
    public var livePct: Double?
    public var levelPct: Double?
    public var startPct: Double?
    /// the arrival % estimate and whether it was stable (60 s)
    public var arrivalPct: Double?
    public var stable: Bool = false
    /// late vs today's estimate at this point, s; the arrival time it gives (epoch s)
    public var lateS: Double?
    public var arriveAtS: Double?

    public init() {}
}

/// What V09 needs each second of a ride
public struct V09Input: Sendable {
    /// epoch seconds (any base in tests)
    public var t: Double
    /// the scooter's own %
    public var pct: Double?
    public var tempC: Double?
    public var rideKm: Double
    public var speedKmh: Double?
    /// The heading now, degrees (nil without GPS course)
    public var courseDeg: Double?
    /// The usual battery %/km (followed route, else recent rides)
    public var usualPctPerKm: Double?
    public var reservePct: Double
    /// Followed route: km of it and where on it now; nil = no route / off it
    public var routeKm: Double?
    public var alongKm: Double?
    /// Seconds since setting off (the ride clock runs from the first riding movement) and the time still to ride (s)
    public var elapsedS: Double
    public var remainingS: Double?
    /// LBP: the learned limit (nil = not learned)
    public var powerLimitPct: Int?
    /// The phone took over / the scooter's readings are not trusted / disconnected
    public var recordingProblem: Bool
    /// A usual stop of this route this far ahead (nil = none known)
    public var usualStopAheadM: Double?
    /// Hotfix 03: power (V × I) and current for the sag-proof level; Wh per 1 % (nil = the prior)
    public var powerW: Double?
    public var currentA: Double?
    public var whPerPct: Double?
    /// The route's past rides point by point, and TODAY's estimate (the time the Where-to chip promised), s
    public var history: RouteHistory?
    public var todayS: Double?
    /// The destination's own name (start line); the phone's offset for clock times
    public var placeName: String?
    public var utcOffsetMin: Int

    public init(t: Double, pct: Double?, tempC: Double? = nil, rideKm: Double, speedKmh: Double? = nil, courseDeg: Double? = nil,
                usualPctPerKm: Double? = nil, reservePct: Double = T.t80ReserveDefaultPct, routeKm: Double? = nil, alongKm: Double? = nil,
                elapsedS: Double = 0, remainingS: Double? = nil, powerLimitPct: Int? = nil,
                recordingProblem: Bool = false, usualStopAheadM: Double? = nil, powerW: Double? = nil, currentA: Double? = nil,
                whPerPct: Double? = nil, history: RouteHistory? = nil, todayS: Double? = nil, placeName: String? = nil, utcOffsetMin: Int = 0) {
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
        self.elapsedS = elapsedS
        self.remainingS = remainingS
        self.powerLimitPct = powerLimitPct
        self.recordingProblem = recordingProblem
        self.usualStopAheadM = usualStopAheadM
        self.powerW = powerW
        self.currentA = currentA
        self.whPerPct = whPerPct
        self.history = history
        self.todayS = todayS
        self.placeName = placeName
        self.utcOffsetMin = utcOffsetMin
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
    /// H1: the arrival estimate must hold within `stableSpreadPts` for `stableS` before anything is said
    public static let stableS = 60.0
    public static let stableSpreadPts = 3.0
    /// H1: nothing in the first 2 km (with route history); without history this ride's rate, silent until 3 km
    public static let quietKm = 2.0
    public static let quietKmNoHistory = 3.0
    /// H1: a battery line only for a number ≥ 5 points worse than the last one; "Back on track" once at ≥ 10 points better
    public static let sharpDropPts = 5.0
    public static let backOnTrackPts = 10.0
    /// B71: no arrival battery line while less than this is left to use on the route (the arrival would sound like the battery now)
    public static let minLeftToUsePts = 5.0
    /// H2: late = behind today's estimate at this point by 5 min, held 60 s, slower than most past rides here, not before 3 km or a
    /// third of the route; again only 5 minutes later; "Back on time" once within a minute
    public static let lateMin = 5
    public static let lateAfterKm = 3.0
    public static let lateHoldS = 60.0
    public static let slowerThanShare = 0.5
    public static let onTimeWithinS = 60.0
    /// H3: the start line a few seconds after setting off; given up after 2 min
    public static let startLineAfterS = 5.0
    public static let startLineUntilS = 120.0
    /// Point of no return: said this far before it, on tight trips (arrival estimate under 20 %)
    public static let pnrBeforeM = 300.0
    /// Power limit: said this many % before the learned limit
    public static let powerLimitAheadPct = 3

    private var engine = EngineTempTracker()
    /// B73: engine lines only once the motor has pushed on this ride (a temperature from before the ride says nothing about now)
    private var motorRan = false
    private var battery = SagProofBattery()
    private var nextTen: Int?
    private var tenStart: Double?
    private var usingMoreSaid: Int?
    private var arrivingLowSaid = false
    private var estWindow: [(t: Double, v: Double)] = []
    /// H1: the arrival % last said (unrounded) or the usual arrival; the last number said (rounded to 5)
    private var batteryRef: Double?
    private var batterySaid: Int?
    /// B71: the last % the voice said (start line, every 10 %, battery lines): never said again by the next battery line
    private var lastPctSaid: Int?
    private var dropSaid = false
    private var backOnTrackSaid = false
    private var along0: Double?
    private var lateSince: Double?
    private var lateSaid = 0
    private var onTimeSince: Double?
    private var backOnTimeSaid = false
    private var startLineDone = false
    private var pnrSaid = false
    private var powerLimitSaid = false
    private var problemSaid = false
    private var problemClearSince: Double?
    private var queue: [(msg: V09Message, t: Double, km: Double)] = []
    private var speeds: [Double] = []
    private var courses: [Double] = []
    /// The numbers behind the voice now (logged with every spoken line)
    public private(set) var numbers = V09Numbers()

    public init() {}

    /// The rested start % (sag-proof), nil before the first reading
    public var startPct: Double? { battery.startPct }

    /// H1: the estimated battery % at arrival, point by point: the level now minus what the route's past rides usually used from this
    /// point to the end (= the usual arrival adjusted by how far ahead / behind usual this ride is now). Without history: this ride's
    /// rate, only from 3 km. nil without a route.
    public static func arrivalPct(level: Double, startPct: Double, rideKm: Double, routeKm: Double?, alongKm: Double?,
                                  history: RouteHistory?) -> Double? {
        guard let routeKm, let alongKm else { return nil }
        if let h = history, h.isUsable, let total = h.usualTotalUsedPct, let here = h.usualUsedPct(atKm: alongKm) {
            return level - max(0, total - here)
        }
        guard rideKm >= quietKmNoHistory, startPct > level else { return nil }
        return level - max(0, routeKm - alongKm) * (startPct - level) / rideKm
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
        numbers = V09Numbers()
        numbers.t = i.t
        numbers.rideKm = i.rideKm
        numbers.alongKm = i.alongKm
        numbers.routeKm = i.routeKm
        numbers.livePct = i.pct

        if (i.currentA ?? 0) >= T.t102PushingCurrentA { motorRan = true }
        if let m = engine.update(tempC: motorRan ? i.tempC : nil, at: i.t) { urgent.append(m) }
        // recording problem: once per problem, again only after 2 min without one
        if i.recordingProblem {
            problemClearSince = nil
            if !problemSaid { problemSaid = true; urgent.append(.recordingProblem) }
        } else if problemSaid {
            if problemClearSince == nil { problemClearSince = i.t }
            if let s = problemClearSince, i.t - s >= 120 { problemSaid = false }
        }

        let whPerPct = i.whPerPct ?? BatteryCalibration.prior().whPerPct
        let level = battery.update(t: i.t, livePct: i.pct, powerW: i.powerW, currentA: i.currentA, speedKmh: i.speedKmh, whPerPct: whPerPct)
        numbers.levelPct = level
        numbers.startPct = battery.startPct
        // H2: where today's estimate says we should be now, and the arrival time from this point
        let remaining = i.remainingS ?? lateRemaining(i)
        if let r = remaining { numbers.arriveAtS = i.t + r }

        // H3: the start line, once, a few seconds after setting off on a known route
        if !startLineDone, i.elapsedS >= Self.startLineAfterS {
            if i.elapsedS > Self.startLineUntilS {
                startLineDone = true
            } else if let place = i.placeName, !place.isEmpty, i.todayS != nil, i.alongKm != nil, let r = remaining, let s = battery.startPct {
                startLineDone = true
                lastPctSaid = Int(s.rounded())
                urgent.append(.startLine(place: place, arriveAt: V09Message.clock(epochS: i.t + r, utcOffsetMin: i.utcOffsetMin),
                                         pct: Int(s.rounded())))
            }
        }

        if let pct = level, let start = battery.startPct {
            // every 10 % (30 % and up; 20 / 15 / 10 keep their own range lines), on the sag-proof level
            if nextTen == nil || (tenStart != start && i.rideKm < 0.05) {
                tenStart = start
                nextTen = (Int(start.rounded(.up)) - 1) / 10 * 10
            }
            if let n = nextTen, pct <= Double(n) {
                let reached = Int((pct / 10).rounded(.up)) * 10
                nextTen = reached - 10
                if reached >= 30 { urgent.append(.everyTen(pct: reached)); lastPctSaid = reached }
            }
            // using more than usual
            if i.rideKm >= Self.usingMoreAfterKm, let usual = i.usualPctPerKm, usual > 0, start > pct {
                let rate = (start - pct) / i.rideKm
                let above = Int(((rate / usual - 1) * 100).rounded())
                if Double(above) >= Self.usingMoreShare * 100, above >= (usingMoreSaid ?? 0) + 10 {
                    usingMoreSaid = above
                    enqueue(.usingMore(pctPerKm: rate, aboveUsualPct: above), i)
                }
            }
            if let arrive = Self.arrivalPct(level: pct, startPct: start, rideKm: i.rideKm, routeKm: i.routeKm, alongKm: i.alongKm,
                                            history: i.history) {
                numbers.arrivalPct = arrive
                batteryLines(arrive, level: pct, start: start, i, &urgent)
                // point of no return (tight trips only), just before it
                if !pnrSaid, arrive < Self.arrivingLowPct, let along = i.alongKm, i.rideKm >= 1, start > pct,
                   let pnr = Self.pointOfNoReturnKm(pct: pct, alongKm: along, ratePctPerKm: (start - pct) / i.rideKm, reservePct: i.reservePct) {
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
        lateLines(i, remaining: remaining)

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

    /// H1: said only when the estimate held steady for a minute; only a number ≥ 5 points worse than the last one (rounded to 5,
    /// always lower than the last number said); better = silent, except one "Back on track" at ≥ 10 points better.
    /// B71: silent while less than 5 points are left to use; never the battery now (rounded) or the same number as the % said just before.
    private mutating func batteryLines(_ arrive: Double, level: Double, start: Double, _ i: V09Input, _ urgent: inout [V09Message]) {
        estWindow.append((i.t, arrive))
        estWindow.removeAll { i.t - $0.t > Self.stableS }
        let hasHistory = i.history?.isUsable == true
        // B71: the window spans 60 s less one reading step (live readings ~1 s apart: 58 s as before; stored rows ~5 s apart: ~55 s;
        // with the old fixed 58 s a replay over stored rows was never steady and said no battery line at all)
        let stepS = estWindow.count >= 2 ? estWindow[estWindow.count - 1].t - estWindow[estWindow.count - 2].t : 0
        guard !Self.arrived(i), i.rideKm >= (hasHistory ? Self.quietKm : Self.quietKmNoHistory), let first = estWindow.first,
              i.t - first.t >= Self.stableS - max(2, stepS), let lo = estWindow.map(\.v).min(), let hi = estWindow.map(\.v).max(),
              hi - lo <= Self.stableSpreadPts else { return }
        let stable = estWindow.map(\.v).reduce(0, +) / Double(estWindow.count)
        numbers.stable = true
        if batteryRef == nil {
            // the yardstick: the usual arrival of this route (what the Where-to chip promised), else the first steady estimate
            if hasHistory, let used = i.history?.usualTotalUsedPct { batteryRef = start - used } else { batteryRef = stable }
        }
        guard let ref = batteryRef else { return }
        let r5 = V09Message.round5(stable)
        guard level - arrive >= Self.minLeftToUsePts, r5 < V09Message.round5(level), r5 != lastPctSaid else { return }
        let below = batterySaid.map { r5 < $0 } ?? true
        if stable <= ref - Self.sharpDropPts, below {
            batteryRef = stable
            batterySaid = r5
            lastPctSaid = r5
            dropSaid = true
            if stable < Self.arrivingLowPct, !arrivingLowSaid {
                arrivingLowSaid = true
                urgent.append(.arrivingLow(pct: r5))
            } else {
                urgent.append(.sharpDrop(pct: r5))
            }
        } else if stable < Self.arrivingLowPct, !arrivingLowSaid, below {
            arrivingLowSaid = true
            batteryRef = stable
            batterySaid = r5
            lastPctSaid = r5
            enqueue(.arrivingLow(pct: r5), i)
        } else if dropSaid, !backOnTrackSaid, stable >= ref + Self.backOnTrackPts {
            backOnTrackSaid = true
            batteryRef = stable
            batterySaid = r5
            lastPctSaid = r5
            enqueue(.backOnTrack(pct: r5), i)
        }
    }

    /// H2: the time still to ride from the route's history when the screen gave none
    private func lateRemaining(_ i: V09Input) -> Double? {
        guard let along = i.alongKm, let today = i.todayS else { return nil }
        if let h = i.history, h.isUsable { return h.todayRemainingS(atKm: along, todayS: today) }
        guard let routeKm = i.routeKm, routeKm > 0 else { return nil }
        return max(0, (routeKm - along) / routeKm * today)
    }

    /// H2: late = behind TODAY's estimate at this point (measured, not projected), with the gates
    private mutating func lateLines(_ i: V09Input, remaining: Double?) {
        guard let along = i.alongKm, let routeKm = i.routeKm, let today = i.todayS, let h = i.history, h.isUsable else {
            lateSince = nil
            return
        }
        if along0 == nil { along0 = along }
        if Self.arrived(i) { lateSince = nil; return }   // at the destination: the arrival line speaks
        let a0 = along0 ?? 0
        let expected = h.todayElapsedS(atKm: along, todayS: today) - h.todayElapsedS(atKm: a0, todayS: today)
        let lateS = i.elapsedS - expected
        numbers.lateS = lateS
        let gate = along - a0 >= Self.lateAfterKm && along >= routeKm / 3
        let share = h.shareFaster(elapsedS: i.elapsedS + (h.usualElapsedS(atKm: a0) ?? 0), atKm: along) ?? 0
        let minutes = Int((lateS / 60).rounded())
        let at = V09Message.clock(epochS: i.t + (remaining ?? 0), utcOffsetMin: i.utcOffsetMin)
        // a queued late line keeps its arrival time fresh
        for k in queue.indices { if case let .runningLate(m, _) = queue[k].msg { queue[k].msg = .runningLate(minutes: m, arriveAt: at) } }
        if gate, lateS >= Double(Self.lateMin * 60), share > Self.slowerThanShare {
            if lateSince == nil { lateSince = i.t }
            if let since = lateSince, i.t - since >= Self.lateHoldS, minutes >= (lateSaid == 0 ? Self.lateMin : lateSaid + Self.lateMin) {
                lateSaid = minutes
                enqueue(.runningLate(minutes: minutes, arriveAt: at), i)
            }
        } else {
            lateSince = nil
        }
        if lateSaid > 0, !backOnTimeSaid, lateS <= Self.onTimeWithinS {
            if onTimeSince == nil { onTimeSince = i.t }
            if let since = onTimeSince, i.t - since >= Self.lateHoldS {
                backOnTimeSaid = true
                queue.removeAll { if case .runningLate = $0.msg { return true } else { return false } }
                enqueue(.backOnTime, i)
            }
        } else {
            onTimeSince = nil
        }
    }

    /// At the end of the followed route (no estimate lines any more)
    static func arrived(_ i: V09Input) -> Bool {
        guard let along = i.alongKm, let routeKm = i.routeKm else { return false }
        return along * 1000 >= routeKm * 1000 - LiveScreenDriver.arrivedWithinM
    }

    private mutating func enqueue(_ m: V09Message, _ i: V09Input) {
        queue.removeAll { Self.sameKind($0.msg, m) }
        queue.append((m, i.t, i.rideKm))
    }

    private static func sameKind(_ a: V09Message, _ b: V09Message) -> Bool { a.kind == b.kind }

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
