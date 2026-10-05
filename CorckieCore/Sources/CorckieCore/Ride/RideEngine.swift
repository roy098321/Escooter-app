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

/// Why the phone took over (G1 phone mode, M1-05).
public enum PhoneModeReason: String, Codable, Sendable {
    /// The scooter link dropped (or went silent) for longer than the takeover wait
    case disconnected
    /// G1b format-change watch: the scooter readings are no longer trusted (SC-04)
    case formatChanged
}

/// A scooter gap inside a ride (G1, `gap` row kind `scooter`): phone mode from `startT` (when the scooter
/// readings went) to `endT` (the first valid frame again).
public struct RideGap: Codable, Equatable, Sendable {
    public var startT: Double
    /// nil while the phone is still in charge
    public var endT: Double?
    public var reason: PhoneModeReason
    /// GPS distance inside the gap, m (only for the live "~N% est.", never for the totals)
    public var gpsM: Double
    /// Scooter battery % when the readings went (the estimate starts here, T49)
    public var batteryAtStartPct: Int?
    public var odoBeforeKm: Double?
    public var odoAfterKm: Double?

    public init(startT: Double, reason: PhoneModeReason, gpsM: Double = 0, batteryAtStartPct: Int? = nil, odoBeforeKm: Double? = nil) {
        self.startT = startT
        self.reason = reason
        self.gpsM = gpsM
        self.batteryAtStartPct = batteryAtStartPct
        self.odoBeforeKm = odoBeforeKm
    }

    public var isOpen: Bool { endT == nil }

    /// M5: the distance the odometer filled in on reconnect, m
    public var odometerFilledM: Double? {
        guard let a = odoBeforeKm, let b = odoAfterKm, b >= a else { return nil }
        return ((b - a) * 1000 * 10).rounded() / 10
    }
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
    /// M1-05: scooter gaps (phone mode stretches); optional so older saved states still decode
    public var gaps: [RideGap]?
    /// Battery % at the start (this ride's %/km for the estimate, decision 5)
    public var firstBatteryPct: Int?

    public var gapList: [RideGap] { gaps ?? [] }

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
    /// G1b format-change watch tripped: the scooter readings are untrusted until the next connect (SC-04)
    case formatChanged
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
    /// G1: the phone took over (open a `gap` row from `at`; banner "Scooter disconnected · reconnecting…" or
    /// "Scooter data format changed")
    case phoneModeStarted(seq: Int, at: Double, reason: PhoneModeReason)
    /// The first valid frame again: close the gap row, scooter numbers back
    case phoneModeEnded(seq: Int, at: Double)
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
    /// Newest scooter temperature (M1-12: motor heat banners)
    public private(set) var temperatureC: Double?
    /// 0x80 seen since the last (re)connect
    public private(set) var shuttingDownSeen = false
    /// After a ride ends, a new one waits until the wheel has been at ≤ T10 once (a held end while rolling)
    public private(set) var armed = true
    /// G1b format change seen (SC-04): readings ignored until the next connect
    public private(set) var untrustedSince: Double?
    /// The last scooter speed before the link went (shown through a blip shorter than the takeover wait)
    public private(set) var heldSpeedKmh: Double?
    /// GPS metres since the scooter readings went (the gap gets them when phone mode starts)
    var goneGpsM = 0.0
    /// The newest frame's own odometer reading (nil when that frame had none, e.g. the first after a reconnect)
    var lastFrameOdoKm: Double?
    /// Usual %/km = median of the last 10 rides (the Recorder sets it; decision 5). nil = not known yet
    public var usualPctPerKm: Double?

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
    /// The ride the offer is for
    public private(set) var pendingSameRideFor: Int?

    /// Fixes are kept this long (≥ the longest GPS-still window, T17 30 s)
    static let fixWindowS = 40.0
    /// A fix older than this is not "now"
    static let fixFreshS = 3.0
    /// Pushing must be broken this long before a walking stretch ends (GPS noise)
    static let pushGraceS = 3.0
    /// M1-05: the phone takes over only after the scooter has been gone this long (P4 build 27: 1-s link drops
    /// reconnect at once and must not switch to phone mode)
    public static let takeoverWaitS = 5.0
    /// G1: GPS speed is the median of this window
    public static let gpsMedianWindowS = 3.0
    /// Decision 5 fallback: 3.0 %/km (ride 2: 41% / 13.7 km)
    public static let defaultPctPerKm = 3.0

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
            if linkLive(at: t) { heldSpeedKmh = speedKmh }
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
        case .formatChanged:
            if untrustedSince == nil, connected {
                if linkLive(at: t) { heldSpeedKmh = speedKmh }
                untrustedSince = t
            }
        case .tick:
            break
        }
        evaluate(at: t, &out)
        return out
    }

    // MARK: Link and phone

    /// Scooter readings are arriving (connected and a frame within T07's 10 s)
    public func linkLive(at t: Double) -> Bool {
        guard connected, untrustedSince == nil, let last = lastFrameT else { return false }
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
        untrustedSince = nil
        shuttingDownSeen = false
        armed = true
        if phase == .idle { phase = .ready }
    }

    private mutating func ingest(_ f: ScooterFrame, at t: Double, _ out: inout [RideEngineEvent]) {
        if untrustedSince != nil, connected {
            integrate(to: t)
            return                         // untrusted readings (SC-04): stored raw by the Recorder, never used
        }
        if !connected {
            reconnected(at: t)            // a log that starts mid-connection
        } else if let last = lastFrameT, t - last > T.t07NoPacketAS {
            reconnected(at: t)            // readings resume after a silent stretch (packet logs have no connect lines)
        }
        integrate(to: t)
        lastFrameT = t
        goneGpsM = 0
        lastFrameOdoKm = f.odometerKm
        if let s = f.speedKmh { speedKmh = s }      // a dropped reading (G1b) keeps the last one
        if let tc = f.temperatureC { temperatureC = tc }
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
            if r.firstBatteryPct == nil { r.firstBatteryPct = batteryPct }
            // M5: the first odometer reading after a gap fills the distance
            if let o = f.odometerKm, var gaps = r.gaps, let i = gaps.indices.last, !gaps[i].isOpen, gaps[i].odoAfterKm == nil {
                gaps[i].odoAfterKm = o
                r.gaps = gaps
            }
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
        let live = linkLive(at: t)
        if live, let s = speedKmh { v = s } else if let g = gpsSpeedNow(at: t) { v = g } else { return }
        let d = v / 3.6 * dt
        r.wheelM += d
        if !live {
            goneGpsM += d
            if var gaps = r.gaps, let i = gaps.indices.last, gaps[i].isOpen {
                gaps[i].gpsM += d
                r.gaps = gaps
            }
        }
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
        r.firstBatteryPct = batteryPct
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
        pendingSameRideFor = nil
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
        updatePhoneMode(at: t, &out)
        updateWalk(at: t, &out)
        updateStops(at: t)
        evaluateEnd(at: t, &out)
    }

    // MARK: Stops (M3, T23–T26)

    private mutating func updateStops(at t: Double) {
        guard phase == .riding, var r = ride else { return }
        let live = linkLive(at: t)
        let v: Double? = live ? speedKmh : gpsSpeedNow(at: t)
        let below = live ? T.t23StopKmh : T.t26PhoneStopKmh
        let need = live ? T.t23StopS : T.t26PhoneStopS
        let walking = r.walks.last?.isOpen ?? false
        defer { ride = r }
        if let i = r.stops.indices.last, r.stops[i].isOpen {
            if walking {
                r.stops[i].endT = t
            } else if let v, v > T.t24StopEndKmh {
                r.stops[i].endT = t                  // T24 hysteresis
                stopCandidateSince = nil
            }
            return
        }
        guard !walking, let v, v < below else {
            stopCandidateSince = nil
            return
        }
        let here = freshFix(at: t)
        guard let since = stopCandidateSince else {
            stopCandidateSince = t
            stopCandidateFix = here
            return
        }
        guard t - since >= need else { return }
        if let a = stopCandidateFix, let b = here, a.metres(to: b) >= T.t23StopMovedM {
            stopCandidateSince = t                   // rolling slowly, not standing (5 m rule)
            stopCandidateFix = b
            return
        }
        // T25: a stop within 10 s and 15 m of the previous one joins it
        if let i = r.stops.indices.last, let end = r.stops[i].endT, since - end < T.t25StopMergeS {
            var near = true
            if let lat = r.stops[i].lat, let lon = r.stops[i].lon, let c = stopCandidateFix ?? here {
                near = EngineFix(t: end, lat: lat, lon: lon, speedKmh: nil).metres(to: c) < T.t25StopMergeM
            }
            if near {
                r.stops[i].endT = nil
                return
            }
        }
        let at = stopCandidateFix ?? here
        r.stops.append(RideSpan(startT: since, lat: at?.lat, lon: at?.lon))
    }

    // MARK: Pushing / walking stretch (D3, T102)

    private mutating func updateWalk(at t: Double, _ out: inout [RideEngineEvent]) {
        guard var r = ride else { return }
        defer { ride = r }
        let live = linkLive(at: t)
        let v: Double? = live ? speedKmh : gpsSpeedNow(at: t)
        var pushing = false
        if let v, v >= T.t102PushingMinKmh, v <= T.t102PushingMaxKmh {
            pushing = live ? (currentA ?? 0) < T.t102PushingCurrentA : true
        }
        let open = r.walks.last?.isOpen ?? false
        if pushing {
            if pushSince == nil {
                pushSince = t
                pushDistanceM = 0
                pushBatteryPct = lastMotorBatteryPct ?? batteryPct
            }
            pushLastTrue = t
            if !open, phase == .riding, r.trimStartT != nil, let since = pushSince, t - since >= T.t102PushingS {
                // A walking stretch from where the pushing began: no stops inside it
                r.stops.removeAll { $0.startT >= since }
                if let i = r.stops.indices.last, r.stops[i].isOpen { r.stops[i].endT = since }
                stopCandidateSince = nil
                let at = fixes.first { $0.t >= since } ?? lastFix
                r.walks.append(RideSpan(startT: since, lat: at?.lat, lon: at?.lon, distanceM: pushDistanceM))
                r.batteryAtWalkStartPct = pushBatteryPct
                r.motorAfterWalk = false
                out.append(.walkStarted(seq: r.seq, at: since))
            }
        } else if let last = pushLastTrue, t - last > Self.pushGraceS {
            if open { r.walks[r.walks.count - 1].endT = last }
            pushSince = nil
            pushLastTrue = nil
        }
    }

    // MARK: End (M2: A, A2, B, C, low battery)

    private mutating func evaluateEnd(at t: Double, _ out: inout [RideEngineEvent]) {
        guard let r = ride else { return }
        let live = linkLive(at: t)
        // Since when the scooter readings are gone (disconnected, connected but silent for T07, or untrusted)
        let goneSince = scooterGoneSince(at: t)
        let lastMove = r.lastMoveT ?? r.startT
        var reason: RideEndReason?
        if !live, shuttingDownSeen {
            reason = .scooterOff                                 // A2: 0x80, then gone: at once
        } else if let g = goneSince, t - g >= T.t17EndDisconnectedS, gpsStill(window: T.t17EndDisconnectedS, at: t) == true {
            reason = .disconnected                               // A: gone 30 s and GPS still
        } else if let g = goneSince, t - g >= T.t18EndNoGpsS, t - lastMove >= T.t17EndDisconnectedS {
            reason = .disconnected                               // A without a good fix: gone 2 min, no movement seen
        } else if t - lastMove >= T.t20EndStandstillS {
            reason = .standstill                                 // C
        }
        guard let reason else { return }
        if phase == .starting {
            cancel(r, reason == .scooterOff ? .scooterOff : .disconnected, at: t, &out)
        } else {
            finish(reason, at: t, &out)
        }
    }

    /// The ride as it would end now (used by `finish` and by recovery).
    public func closing(_ reason: RideEndReason, at t: Double) -> RideEnd? {
        guard var r = ride else { return nil }
        let endT = max(r.startT, min(t, r.lastMoveT ?? t))
        // A stop still open at the end is the standstill after the last movement, not a stop
        r.stops.removeAll { $0.isOpen || $0.startT >= endT }
        for i in r.stops.indices { r.stops[i].endT = min(r.stops[i].endT ?? endT, endT) }
        r.walks.removeAll { $0.startT >= endT }
        if let i = r.walks.indices.last, r.walks[i].isOpen { r.walks[i].endT = min(pushLastTrue ?? endT, endT) }
        // A gap that began after the last movement is not inside the ride; one still open closes at the end
        if var gaps = r.gaps {
            gaps.removeAll { $0.startT >= endT }
            if let i = gaps.indices.last, gaps[i].isOpen { gaps[i].endT = endT }
            r.gaps = gaps.isEmpty ? nil : gaps
        }
        let distance = r.distanceAfterTrimM
        var lowBattery: Int?
        if reason == .scooterOff || reason == .disconnected, let b = r.lastBatteryPct, Double(b) <= T.t80ReserveDefaultPct {
            lowBattery = b
        }
        var ranOut: Int?
        if !r.walks.isEmpty, !r.motorAfterWalk, let pct = r.batteryAtWalkStartPct, Double(pct) <= T.t81LowBatteryPct {
            ranOut = pct
        }
        return RideEnd(ride: r, reason: reason, endT: endT, decidedAtT: t, distanceM: distance,
                       sizeClass: RideSizeClass.of(distanceM: distance), lowBatteryOffPct: lowBattery, batteryRanOutPct: ranOut)
    }

    private mutating func finish(_ reason: RideEndReason, at t: Double, _ out: inout [RideEngineEvent]) {
        guard let end = closing(reason, at: t) else { return }
        if let pct = end.batteryRanOutPct { out.append(.batteryRanOut(seq: end.ride.seq, pct: pct)) }
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

    // MARK: Same ride (M2, T21)

    private mutating func offerSameRide(at t: Double, _ out: inout [RideEngineEvent]) {
        guard let prev = lastEnd, prev.automatic, let r = ride, r.startT - prev.endT <= T.t21SameRideS else { return }
        if let lat = prev.ride.lastLat, let lon = prev.ride.lastLon {
            var start = freshFix(at: t)
            if let sLat = r.startLat, let sLon = r.startLon { start = EngineFix(t: r.startT, lat: sLat, lon: sLon, speedKmh: nil) }
            if let start, EngineFix(t: prev.endT, lat: lat, lon: lon, speedKmh: nil).metres(to: start) > T.t21SameRideM { return }
        }
        pendingSameRideSeq = prev.ride.seq
        pendingSameRideFor = r.seq
        out.append(.sameRideOffered(seq: r.seq, previousSeq: prev.ride.seq))
    }

    private mutating func answerSameRide(_ yes: Bool, _ out: inout [RideEngineEvent]) {
        guard let prevSeq = pendingSameRideSeq, let forSeq = pendingSameRideFor else { return }
        pendingSameRideSeq = nil
        pendingSameRideFor = nil
        guard yes else { return }
        // Join the earlier ride's group (a chain of pieces keeps one group)
        var group = prevSeq
        if let e = lastEnd, e.ride.seq == prevSeq, let g = e.ride.mergedIntoSeq { group = g }
        if var r = ride, r.seq == forSeq {
            r.mergedIntoSeq = group
            ride = r
        } else if var e = lastEnd, e.ride.seq == forSeq {
            e.ride.mergedIntoSeq = group      // answered after the piece already ended
            lastEnd = e
        } else {
            return
        }
        out.append(.rideMerged(seq: forSeq, intoSeq: group))
    }

    // MARK: Recovery (M2 "Recovery", SC-14)

    /// The app was relaunched with this state restored: the link and the phone start from scratch.
    public mutating func relaunched(at t: Double) {
        now = max(now, t)
        connected = false
        disconnectedAt = t
        lastFrameT = nil
        speedKmh = nil
        currentA = nil
        currentAboveSince = nil
        gpsFastSince = nil
        stopCandidateSince = nil
        fixes = []
        lastFix = nil
        lastIntegrateT = t
        if phase == .ready { phase = .idle }
    }

    /// Forget the open ride (after recovery ended or discarded it).
    public mutating func dropOpenRide() {
        ride = nil
        connected = false
        afterRide()
    }

    // MARK: Phone takeover (M1-05, G1)

    /// Since when the scooter readings are gone: disconnected, connected but silent for T07, or untrusted (G1b).
    /// nil = the readings are live.
    public func scooterGoneSince(at t: Double) -> Double? {
        if let u = untrustedSince { return u }
        if linkLive(at: t) { return nil }
        return connected ? (lastFrameT ?? disconnectedAt) : (disconnectedAt ?? lastFrameT)
    }

    /// Phone mode: a ride is on and the scooter readings have been gone for the takeover wait (~5 s), or are
    /// untrusted (the format watch already took its time).
    public func phoneMode(at t: Double) -> Bool {
        guard rideActive, let g = scooterGoneSince(at: t) else { return false }
        return untrustedSince != nil || t - g >= Self.takeoverWaitS
    }

    private mutating func updatePhoneMode(at t: Double, _ out: inout [RideEngineEvent]) {
        guard var r = ride else { return }
        let open = r.gaps?.last?.isOpen ?? false
        if phoneMode(at: t) {
            guard !open, let g = scooterGoneSince(at: t) else { return }
            let reason: PhoneModeReason = untrustedSince != nil ? .formatChanged : .disconnected
            var gaps = r.gaps ?? []
            gaps.append(RideGap(startT: g, reason: reason, gpsM: goneGpsM, batteryAtStartPct: r.lastBatteryPct, odoBeforeKm: r.odoLastKm))
            r.gaps = gaps
            ride = r
            out.append(.phoneModeStarted(seq: r.seq, at: g, reason: reason))
        } else if open, linkLive(at: t), var gaps = r.gaps, let i = gaps.indices.last {
            gaps[i].endT = t
            gaps[i].odoAfterKm = lastFrameOdoKm
            r.gaps = gaps
            ride = r
            out.append(.phoneModeEnded(seq: r.seq, at: t))
        }
    }

    /// G1: GPS speed = median of the good fixes of the last 3 s (nil without a fresh fix with a speed).
    public func gpsMedianKmh(at t: Double) -> Double? {
        guard freshFix(at: t) != nil else { return nil }
        let v = fixes.filter { $0.t >= t - Self.gpsMedianWindowS - 0.001 && $0.t <= t + 0.001 }.compactMap { $0.speedKmh }.sorted()
        guard !v.isEmpty else { return nil }
        let n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }

    /// Decision 5: usual %/km (median of the last 10 rides), else this ride's %/km after 1 km, else 3.0.
    public var pctPerKmForEstimate: Double {
        if let u = usualPctPerKm, u > 0 { return u }
        if let r = ride, let a = r.firstBatteryPct, let b = r.gapList.last?.batteryAtStartPct ?? r.lastBatteryPct,
           r.distanceAfterTrimM >= T.t43BatteryPerKmAfterM, a > b {
            return Double(a - b) / (r.distanceAfterTrimM / 1000)
        }
        return Self.defaultPctPerKm
    }

    /// T49 "~N% est.": last scooter battery % − %/km × GPS km since the drop. nil outside phone mode.
    public func estimatedBatteryPct(at t: Double) -> Double? {
        guard phoneMode(at: t), let r = ride, let gap = r.gapList.last, gap.isOpen,
              let base = gap.batteryAtStartPct ?? r.lastBatteryPct else { return nil }
        return max(0, Double(base) - pctPerKmForEstimate * gap.gpsM / 1000)
    }

    // MARK: Live view hand-off (M1-07 contract)

    public func liveInput(at t: Double, mapOffline: Bool = false) -> LiveInput {
        let linked = linkLive(at: t)
        let phone = phoneMode(at: t)
        // A blip shorter than the takeover wait keeps the scooter numbers (no switch for a 1-s drop)
        var blip = false
        if !linked, !phone, untrustedSince == nil, let g = scooterGoneSince(at: t), t - g < Self.takeoverWaitS {
            blip = (speedKmh ?? heldSpeedKmh) != nil
        }
        let noGps = lastFix.map { max(0, t - $0.t) } ?? (ride.map { t - $0.startT } ?? 0)
        return LiveInput(scooterSpeedKmh: linked ? speedKmh : (blip ? (speedKmh ?? heldSpeedKmh) : nil),
                         gpsSpeedKmh: gpsMedianKmh(at: t),
                         scooterLinked: linked || blip,
                         scooterBatteryPct: batteryPct.map(Double.init),
                         estimatedBatteryPct: phone ? estimatedBatteryPct(at: t) : nil,
                         starting: phase == .starting,
                         secondsWithoutGps: freshFix(at: t) == nil ? noGps : 0,
                         mapOffline: mapOffline, phase: phase,
                         scooterTempC: linked ? temperatureC : nil, phoneMode: phone,
                         formatChanged: untrustedSince != nil, sameRideOffered: pendingSameRideSeq != nil,
                         lat: lastFix?.lat, lon: lastFix?.lon, rideElapsedS: ride.map { max(0, t - $0.startT) },
                         rideDistanceM: ride.map { $0.wheelM })
    }
}
