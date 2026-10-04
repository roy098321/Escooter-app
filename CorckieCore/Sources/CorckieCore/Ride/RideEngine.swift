import Foundation

// The ride engine (M1-03 / M1-04): ONE state machine in Core (M1_PLAN §6 decision 4), driven only by
// time-stamped inputs, so a recorded or synthetic ride replays through exactly what runs on the street.
// Times are seconds on the caller's clock (the Recorder uses epoch seconds, the tests a virtual clock).
//
//   idle (no scooter) → ready (connected) → starting (stage 1) → riding (confirmed) → ride ends → ready / idle
//
// Inputs: scooter connect / disconnect, every checked frame (after G1b), every phone fix, the buttons
// (Start ride, Not riding, hold to end, Same ride?) and a tick about once a second (for the timeouts).
// Outputs: events the Recorder acts on (create / delete / close the ride row, start location at stage 1,
// Notifier.rideStarted(), banners). The phone takeover display (M1-05) and the Recorder (M1-09) plug in
// here; they read `phase`, `ride`, `liveInput(at:)` and the events, nothing else.

public enum RidePhase: String, Codable, Sendable {
    /// Scooter not connected: nothing can start (v1 rule, M1 pre-condition)
    case idle
    /// Connected and trusted, no ride
    case ready
    /// Stage 1: ride row exists, clock running, "starting…" dot
    case starting
    /// Confirmed ride
    case riding
}

/// Which stage-2 signal confirmed the ride (check t3 records it).
public enum RideConfirmSignal: String, Codable, Sendable {
    /// Motor current > T11 for 1 s
    case current
    /// GPS speed > T12 for 3 s
    case gpsSpeed
    /// GPS moved T13 while the wheel moved
    case gpsDistance
    /// Start ride pressed (skips stage 2)
    case manual
}

/// Why a started ride was dropped without a trace (silent cancel: ride row deleted, no message).
public enum RideCancelReason: String, Codable, Sendable {
    /// GPS still for T14 while the wheel "moves" (wheel spin on the stand)
    case gpsStill
    /// Not confirmed within T15
    case unconfirmed
    /// "Not riding" tapped
    case notRiding
    /// The scooter switched itself off before the ride was confirmed
    case scooterOff
    /// The scooter went away before the ride was confirmed (rule A while starting)
    case disconnected
}

/// `ride.endReason` (DATA_MODEL: disconnected / held / standstill / scooterOff / recovered).
public enum RideEndReason: String, Codable, Sendable {
    case disconnected
    case held
    case standstill
    case scooterOff
    case recovered
}

/// M36 size class = `ride.kind`.
public enum RideSizeClass: String, Codable, Sendable {
    case ride
    case shortHop
    case discarded

    /// M36: < 0.5 km discarded (kept T22), 0.5–2 km short hop, > 2 km ride
    public static let discardBelowM = 500.0
    public static let shortHopBelowM = 2_000.0

    public static func of(distanceM: Double) -> RideSizeClass {
        let d = (distanceM * 10).rounded() / 10      // odometer steps are 0.1 km: no float edge at 500 m
        if d < discardBelowM { return .discarded }
        if d < shortHopBelowM { return .shortHop }
        return .ride
    }
}

/// A good phone fix as the engine keeps it (Codable, so the state survives an app relaunch).
public struct EngineFix: Codable, Equatable, Sendable {
    public var t: Double
    public var lat: Double
    public var lon: Double
    /// km/h, nil = the phone gave no speed
    public var speedKmh: Double?

    public init(t: Double, lat: Double, lon: Double, speedKmh: Double?) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.speedKmh = speedKmh
    }

    public init(_ f: PhoneFix) {
        self.init(t: f.t, lat: f.lat, lon: f.lon, speedKmh: f.speedMps >= 0 ? f.speedMps * 3.6 : nil)
    }

    /// Flat-earth metres; fine for the few hundred metres the rules compare.
    public func metres(to b: EngineFix) -> Double {
        let dLat = (lat - b.lat) * 111_320
        let dLon = (lon - b.lon) * 111_320 * cos(lat * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}

/// A stretch inside a ride on the engine clock: a stop (M3) or a walking stretch (D3 / T102).
public struct RideSpan: Codable, Equatable, Sendable {
    public var startT: Double
    /// nil while it is still open
    public var endT: Double?
    public var lat: Double?
    public var lon: Double?
    /// Walking stretches: metres walked (wheel speed, or GPS speed without the scooter)
    public var distanceM: Double

    public init(startT: Double, endT: Double? = nil, lat: Double? = nil, lon: Double? = nil, distanceM: Double = 0) {
        self.startT = startT
        self.endT = endT
        self.lat = lat
        self.lon = lon
        self.distanceM = distanceM
    }

    public var isOpen: Bool { endT == nil }

    public func contains(_ t: Double) -> Bool { t >= startT && t <= (endT ?? .infinity) }
}

/// The ride the engine is working on.
public struct EngineRide: Codable, Equatable, Sendable {
    /// Engine-local number; the Recorder maps it to the ride row id
    public var seq: Int
    /// Stage 1 (or Start ride pressed): the ride row's `startAt`
    public var startT: Double
    public var manual: Bool
    public var confirmedAt: Double?
    public var confirmedBy: RideConfirmSignal?
    public var firstMoveT: Double?
    /// Last movement of any kind (walking counts, D3): the end time of the ride
    public var lastMoveT: Double?
    /// Walking trim (M1, T16): first moment at riding pace or with motor power; nil = walking only so far
    public var trimStartT: Double?
    public var odoStartKm: Double?
    public var odoTrimKm: Double?
    public var odoLastKm: Double?
    /// Wheel distance (GPS distance without the scooter), integrated, m; the odometer is preferred
    public var wheelM: Double = 0
    public var wheelAtTrimM: Double?
    public var startLat: Double?
    public var startLon: Double?
    public var lastLat: Double?
    public var lastLon: Double?
    /// M3 stops
    public var stops: [RideSpan] = []
    /// D3 walking stretches (pushing)
    public var walks: [RideSpan] = []
    public var lastBatteryPct: Int?
    /// D3: the battery % when the motor last ran before the newest walking stretch
    public var batteryAtWalkStartPct: Int?
    /// The motor ran again after the newest walking stretch began (then it was not "battery ran out")
    public var motorAfterWalk = false
    /// The first GPS fix after stage 1 (T13 "GPS moved 50 m" is measured from here)
    public var anchorFix: EngineFix?
    /// Same ride: the earlier ride this one joins (`mergeGroupId`), set when the rider says Yes
    public var mergedIntoSeq: Int?

    public init(seq: Int, startT: Double, manual: Bool) {
        self.seq = seq
        self.startT = startT
        self.manual = manual
    }

    public var confirmed: Bool { confirmedAt != nil }

    /// Distance after the walking trim, m: odometer when there is one, else the integrated wheel / GPS distance.
    public var distanceAfterTrimM: Double {
        guard trimStartT != nil else { return 0 }
        if let a = odoTrimKm ?? odoStartKm, let b = odoLastKm, b >= a {
            return ((b - a) * 1000 * 10).rounded() / 10
        }
        return max(0, wheelM - (wheelAtTrimM ?? 0))
    }

    public var walkedM: Double { walks.reduce(0) { $0 + $1.distanceM } }
}

/// What the engine hands over when a ride ends (the Recorder closes the row from it).
public struct RideEnd: Codable, Equatable, Sendable {
    public var ride: EngineRide
    public var reason: RideEndReason
    /// End time = last movement (CALC_SPEC M2)
    public var endT: Double
    /// When the end rule fired
    public var decidedAtT: Double
    /// M5 after the walking trim, m (the Recorder re-computes it from the samples, M1-06)
    public var distanceM: Double
    public var sizeClass: RideSizeClass
    /// "ended: scooter switched off at N%" (last battery ≤ 5% at a disconnect / switch-off)
    public var lowBatteryOffPct: Int?
    /// D3 / T80: the % where the battery ran out (pushed to the end with the motor off)
    public var batteryRanOutPct: Int?

    /// `ride.status`: recovered rides keep their own status
    public var status: String { reason == .recovered ? "recovered" : "ended" }
    /// Automatic ends can be joined by "Same ride?" (T21); a held end cannot
    public var automatic: Bool { reason != .held }
}

public enum RideEngineInput: Equatable, Sendable {
    case connected
    case disconnected
    /// A checked frame (after G1b)
    case frame(ScooterFrame)
    case fix(PhoneFix)
    /// Home → Start ride (or the App Shortcut): skips stage 2
    case startPressed
    /// Live view → Not riding: silent cancel
    case notRidingPressed
    /// The stop button was held T19 (the view times the hold)
    case endHeld
    /// Answer to the "Same ride?" banner
    case sameRideAnswer(Bool)
    /// About once a second, so the timeouts run without data
    case tick
}

public enum RideEngineEvent: Equatable, Sendable {
    /// Stage 1: create the ride row (`recording`), start location, `Notifier.shared.rideStarted()`, live view
    case rideStarted(seq: Int, at: Double, manual: Bool)
    /// Stage 2: hide the "starting…" dot, release the queued ride-start messages
    case rideConfirmed(seq: Int, at: Double, by: RideConfirmSignal)
    /// Silent cancel: delete the ride row, back to Home, no message
    case rideCancelled(seq: Int, at: Double, reason: RideCancelReason)
    /// Show "Same ride?" (tappable while stopped)
    case sameRideOffered(seq: Int, previousSeq: Int)
    /// Yes: the new piece joins the earlier ride's `mergeGroupId`
    case rideMerged(seq: Int, intoSeq: Int)
    /// D3: a walking stretch began (at its start time)
    case walkStarted(seq: Int, at: Double)
    /// D3 / T80: save the % as the real empty point for range
    case batteryRanOut(seq: Int, pct: Int)
    /// Close the ride row (end reason, end time, size class)
    case rideEnded(RideEnd)
}

public struct RideEngine: Codable, Equatable, Sendable {
    public private(set) var phase: RidePhase = .idle
    public private(set) var ride: EngineRide?
    /// The last ride that ended (for "Same ride?")
    public private(set) var lastEnd: RideEnd?
    public private(set) var nextSeq = 1
    /// Newest input time
    public private(set) var now: Double = 0

    // Scooter link
    public private(set) var connected = false
    public private(set) var disconnectedAt: Double?
    public private(set) var lastFrameT: Double?
    public private(set) var speedKmh: Double?
    public private(set) var currentA: Double?
    public private(set) var batteryPct: Int?
    public private(set) var odometerKm: Double?
    /// 0x80 seen since the last (re)connect
    public private(set) var shuttingDownSeen = false
    /// After a ride ends, a new one waits until the wheel has been at ≤ T10 once (a held end while rolling)
    public private(set) var armed = true

    // Phone
    /// Good fixes of the last `fixWindowS`
    var fixes: [EngineFix] = []
    public private(set) var lastFix: EngineFix?

    // Stage 2 trackers
    var currentAboveSince: Double?
    var gpsFastSince: Double?
    var lastMotorBatteryPct: Int?
    var lastIntegrateT: Double?

    // M1-04 trackers
    var stopCandidateSince: Double?
    var stopCandidateFix: EngineFix?
    var pushSince: Double?
    var pushLastTrue: Double?
    var pushDistanceM = 0.0
    var pushBatteryPct: Int?
    /// Previous ride offered as "Same ride?", waiting for the answer
    public private(set) var pendingSameRideSeq: Int?

    /// Fixes are kept this long (≥ the longest GPS-still window, T17 30 s)
    static let fixWindowS = 40.0
    /// A fix older than this is not "now"
    static let fixFreshS = 3.0
    /// Pushing must be broken this long before a walking stretch ends (GPS noise)
    static let pushGraceS = 3.0

    public init() {}

    /// A ride row exists (stage 1 or later): `Notifier.shared.rideActive`
    public var rideActive: Bool { phase == .starting || phase == .riding }

    // MARK: Input

    @discardableResult
    public mutating func handle(_ input: RideEngineInput, at t: Double) -> [RideEngineEvent] {
        var out: [RideEngineEvent] = []
        now = max(now, t)
        switch input {
        case .connected:
            reconnected(at: t)
        case .disconnected:
            if connected { disconnectedAt = t }
            connected = false
            speedKmh = nil
            currentA = nil
            currentAboveSince = nil
            if phase == .ready { phase = .idle }
        case .frame(let f):
            ingest(f, at: t, &out)
        case .fix(let f):
            ingest(f)
        case .startPressed:
            startByHand(at: t, &out)
        case .notRidingPressed:
            if let r = ride { cancel(r, .notRiding, at: t, &out) }
        case .endHeld:
            if ride != nil { finish(.held, at: t, &out) }
        case .sameRideAnswer(let yes):
            answerSameRide(yes, &out)
        case .tick:
            break
        }
        evaluate(at: t, &out)
        return out
    }

    // MARK: Link and phone

    /// Scooter readings are arriving (connected and a frame within T07's 10 s)
    public func linkLive(at t: Double) -> Bool {
        guard connected, let last = lastFrameT else { return false }
        return t - last <= T.t07NoPacketAS
    }

    /// Newest fix if it is fresh
    func freshFix(at t: Double) -> EngineFix? {
        guard let f = lastFix, t - f.t <= Self.fixFreshS, t >= f.t - 1 else { return nil }
        return f
    }

    func gpsSpeedNow(at t: Double) -> Double? { freshFix(at: t)?.speedKmh }

    func wheelMoves(at t: Double) -> Bool {
        linkLive(at: t) && (speedKmh ?? 0) > T.t10AutostartKmh
    }

    /// T27 over a window: GPS < 2 km/h and moved < 15 m. nil = not enough good fixes to tell.
    public func gpsStill(window w: Double, at t: Double) -> Bool? {
        let inWindow = fixes.filter { $0.t >= t - w - 0.001 && $0.t <= t + 0.001 }
        guard let first = inWindow.first, let last = inWindow.last,
              t - last.t <= Self.fixFreshS, last.t - first.t >= w - 2 else { return nil }
        if inWindow.contains(where: { ($0.speedKmh ?? 0) >= T.t27GpsStillKmh }) { return false }
        let farthest = inWindow.map { first.metres(to: $0) }.max() ?? 0
        return farthest < T.t27GpsStillM
    }

    private mutating func reconnected(at t: Double) {
        connected = true
        disconnectedAt = nil
        shuttingDownSeen = false
        armed = true
        if phase == .idle { phase = .ready }
    }

    private mutating func ingest(_ f: ScooterFrame, at t: Double, _ out: inout [RideEngineEvent]) {
        if !connected {
            reconnected(at: t)            // a log that starts mid-connection
        } else if let last = lastFrameT, t - last > T.t07NoPacketAS {
            reconnected(at: t)            // readings resume after a silent stretch (packet logs have no connect lines)
        }
        integrate(to: t)
        lastFrameT = t
        if let s = f.speedKmh { speedKmh = s }      // a dropped reading (G1b) keeps the last one
        currentA = f.currentA
        if let b = f.batteryPct { batteryPct = b }
        if let o = f.odometerKm { odometerKm = o }
        if f.shuttingDown { shuttingDownSeen = true }
        if let s = speedKmh, s <= T.t10AutostartKmh { armed = true }

        if let c = currentA, c > T.t11ConfirmCurrentA {
            if currentAboveSince == nil { currentAboveSince = t }
        } else {
            currentAboveSince = nil
        }
        let motorOn = (currentA ?? 0) >= T.t102PushingCurrentA
        if motorOn { lastMotorBatteryPct = batteryPct }

        if var r = ride {
            if r.odoStartKm == nil { r.odoStartKm = odometerKm }
            if odometerKm != nil { r.odoLastKm = odometerKm }
            r.lastBatteryPct = batteryPct
            if motorOn, !r.walks.isEmpty { r.motorAfterWalk = true }
            ride = r
        }

        // Stage 1: wheel speed > T10 while connected
        if phase == .ready, armed, !shuttingDownSeen, let s = speedKmh, s > T.t10AutostartKmh {
            begin(at: t, manual: false, &out)
        }
    }

    private mutating func ingest(_ p: PhoneFix) {
        guard p.isGood else { return }
        let f = EngineFix(p)
        integrate(to: f.t)
        if let v = f.speedKmh {
            if v > T.t12ConfirmGpsKmh {
                if gpsFastSince == nil { gpsFastSince = f.t }
            } else {
                gpsFastSince = nil
            }
        }
        lastFix = f
        fixes.append(f)
        fixes.removeAll { $0.t < f.t - Self.fixWindowS }
        if var r = ride {
            if r.anchorFix == nil { r.anchorFix = f }
            if r.startLat == nil {
                r.startLat = f.lat
                r.startLon = f.lon
            }
            r.lastLat = f.lat
            r.lastLon = f.lon
            ride = r
        }
    }

    /// Wheel (or GPS) distance since the last input, added to the ride and the open walking stretch.
    private mutating func integrate(to t: Double) {
        defer { lastIntegrateT = max(lastIntegrateT ?? t, t) }
        guard var r = ride, let last = lastIntegrateT else { return }
        let dt = t - last
        guard dt > 0, dt <= 2.5 else { return }
        let v: Double
        if linkLive(at: t), let s = speedKmh { v = s } else if let g = gpsSpeedNow(at: t) { v = g } else { return }
        let d = v / 3.6 * dt
        r.wheelM += d
        if let i = r.walks.indices.last, r.walks[i].isOpen { r.walks[i].distanceM += d }
        if pushSince != nil { pushDistanceM += d }
        ride = r
    }

    // MARK: Start (M1-03)

    private mutating func begin(at t: Double, manual: Bool, _ out: inout [RideEngineEvent]) {
        var r = EngineRide(seq: nextSeq, startT: t, manual: manual)
        nextSeq += 1
        r.odoStartKm = odometerKm
        r.odoLastKm = odometerKm
        r.lastBatteryPct = batteryPct
        if let f = freshFix(at: t) {
            r.anchorFix = f
            r.startLat = f.lat
            r.startLon = f.lon
            r.lastLat = f.lat
            r.lastLon = f.lon
        }
        ride = r
        phase = .starting
        lastIntegrateT = t
        pushSince = nil
        pushLastTrue = nil
        stopCandidateSince = nil
        pendingSameRideSeq = nil
        out.append(.rideStarted(seq: r.seq, at: t, manual: manual))
        if manual { confirm(.manual, at: t, &out) }
    }

    private mutating func startByHand(at t: Double, _ out: inout [RideEngineEvent]) {
        switch phase {
        case .ready:
            begin(at: t, manual: true, &out)
        case .starting:
            confirm(.manual, at: t, &out)
        case .idle, .riding:
            break       // no scooter (v1: nothing starts without it), or already riding
        }
    }

    private mutating func confirm(_ signal: RideConfirmSignal, at t: Double, _ out: inout [RideEngineEvent]) {
        guard var r = ride, !r.confirmed else { return }
        r.confirmedAt = t
        r.confirmedBy = signal
        ride = r
        phase = .riding
        out.append(.rideConfirmed(seq: r.seq, at: t, by: signal))
        offerSameRide(at: t, &out)
    }

    /// Stage 2 and the silent cancels, while starting.
    private mutating func evaluateStarting(at t: Double, _ out: inout [RideEngineEvent]) {
        guard let r = ride, phase == .starting else { return }
        if let since = currentAboveSince, linkLive(at: t), t - since >= T.t11ConfirmCurrentS {
            return confirm(.current, at: t, &out)
        }
        if let since = gpsFastSince, freshFix(at: t) != nil, t - since >= T.t12ConfirmGpsS {
            return confirm(.gpsSpeed, at: t, &out)
        }
        if let anchor = r.anchorFix, let here = freshFix(at: t), wheelMoves(at: t),
           anchor.metres(to: here) >= T.t13ConfirmGpsDistanceM {
            return confirm(.gpsDistance, at: t, &out)
        }
        // Silent cancel: GPS still for T14 while the wheel turns (good fixes only)
        if wheelMoves(at: t), t - r.startT >= T.t14CancelGpsStillS, gpsStill(window: T.t14CancelGpsStillS, at: t) == true {
            return cancel(r, .gpsStill, at: t, &out)
        }
        if t - r.startT >= T.t15CancelUnconfirmedS {
            return cancel(r, .unconfirmed, at: t, &out)
        }
    }

    private mutating func cancel(_ r: EngineRide, _ reason: RideCancelReason, at t: Double, _ out: inout [RideEngineEvent]) {
        out.append(.rideCancelled(seq: r.seq, at: t, reason: reason))
        ride = nil
        afterRide()
    }

    /// Walking trim (T16): the first moment at riding pace or with motor power.
    private mutating func trackTrim(at t: Double) {
        guard var r = ride, r.trimStartT == nil else { return }
        let fast: Bool
        if linkLive(at: t) {
            fast = (speedKmh ?? 0) >= T.t16WalkingKmh || (currentA ?? 0) >= T.t16WalkingCurrentA
        } else {
            fast = (gpsSpeedNow(at: t) ?? 0) >= T.t16WalkingKmh
        }
        guard fast else { return }
        r.trimStartT = t
        r.odoTrimKm = odometerKm ?? r.odoLastKm
        r.wheelAtTrimM = r.wheelM
        ride = r
    }

    /// Any movement at all (walking counts, D3): wheel ≥ 1 km/h, or GPS ≥ 2 km/h without the scooter.
    func movingNow(at t: Double) -> Bool {
        if linkLive(at: t) { return (speedKmh ?? 0) >= T.t102PushingMinKmh }
        return (gpsSpeedNow(at: t) ?? 0) >= T.t27GpsStillKmh
    }

    private mutating func trackMovement(at t: Double) {
        guard var r = ride, movingNow(at: t) else { return }
        if r.firstMoveT == nil { r.firstMoveT = t }
        r.lastMoveT = t
        ride = r
    }

    // MARK: Evaluate

    private mutating func evaluate(at t: Double, _ out: inout [RideEngineEvent]) {
        integrate(to: t)
        guard ride != nil else { return }
        trackTrim(at: t)
        trackMovement(at: t)
        if phase == .starting { evaluateStarting(at: t, &out) }
        guard ride != nil else { return }
        evaluateEnd(at: t, &out)
    }

    // MARK: End (M1-04 fills the rules in)

    private mutating func evaluateEnd(at t: Double, _ out: inout [RideEngineEvent]) {}

    private mutating func finish(_ reason: RideEndReason, at t: Double, _ out: inout [RideEngineEvent]) {
        guard let r = ride else { return }
        let endT = max(r.startT, min(t, r.lastMoveT ?? t))
        let distance = r.distanceAfterTrimM
        let end = RideEnd(ride: r, reason: reason, endT: endT, decidedAtT: t, distanceM: distance,
                          sizeClass: RideSizeClass.of(distanceM: distance), lowBatteryOffPct: nil, batteryRanOutPct: nil)
        out.append(.rideEnded(end))
        lastEnd = end
        ride = nil
        afterRide()
    }

    private mutating func afterRide() {
        phase = connected ? .ready : .idle
        armed = (speedKmh ?? 0) <= T.t10AutostartKmh
        currentAboveSince = nil
        gpsFastSince = nil
        stopCandidateSince = nil
        stopCandidateFix = nil
        pushSince = nil
        pushLastTrue = nil
        pushDistanceM = 0
    }

    // MARK: Same ride (M1-04)

    private mutating func offerSameRide(at t: Double, _ out: inout [RideEngineEvent]) {}

    private mutating func answerSameRide(_ yes: Bool, _ out: inout [RideEngineEvent]) {}

    // MARK: Live view hand-off (M1-07 contract; M1-05 swaps in the 3-s GPS median and the estimate)

    public func liveInput(at t: Double, mapOffline: Bool = false) -> LiveInput {
        let linked = linkLive(at: t)
        let noGps = lastFix.map { max(0, t - $0.t) } ?? (ride.map { t - $0.startT } ?? 0)
        return LiveInput(scooterSpeedKmh: linked ? speedKmh : nil,
                         gpsSpeedKmh: gpsSpeedNow(at: t),
                         scooterLinked: linked,
                         scooterBatteryPct: batteryPct.map(Double.init),
                         estimatedBatteryPct: nil,
                         starting: phase == .starting,
                         secondsWithoutGps: freshFix(at: t) == nil ? noGps : 0,
                         mapOffline: mapOffline)
    }
}
