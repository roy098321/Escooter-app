import Foundation

// M1-09: the pure part of the Recorder. It owns the ride path (RideFeed → RideEngine), the 5-s RideSampler, the
// live held top speed (M1-06 note), the raw scooter packets of the open ride, and the timers (samples / raw chunk /
// ride row every 30 s, engine snapshot every 5 s, live input every second). It only *says* what to store: the app's
// Recorder actor applies the actions to the database (App/Store) and the notifier, the tests apply them to memory.
// Times are seconds on the caller's clock (the app: epoch seconds; the simulator: the fixture's clock).

/// One stored sample with its `ride_sample.mode` (scooter / phone / walk).
public struct RecorderSample: Equatable, Sendable {
    public var sample: RideSample
    public var mode: String

    public init(sample: RideSample, mode: String) {
        self.sample = sample
        self.mode = mode
    }
}

/// What the ride row gets every 30 s while recording (crash safety: the row is never far behind).
public struct RecorderProgress: Equatable, Sendable {
    public var seq: Int
    public var odoStartKm: Double?
    public var odoLastKm: Double?
    public var distanceM: Double
    public var firstMoveT: Double?
    public var lastMoveT: Double?
    /// Live held top speed (every checked frame, not only the 5-s samples)
    public var topSpeedKmh: Double
    public var lastBatteryPct: Int?
}

/// The ride closed: the engine's end, the held top speed and the readings G1b dropped during this ride.
public struct RecorderClose: Equatable, Sendable {
    public var end: RideEnd
    public var topSpeedKmh: Double
    public var ignoredReadings: Int

    public init(end: RideEnd, topSpeedKmh: Double, ignoredReadings: Int) {
        self.end = end
        self.topSpeedKmh = topSpeedKmh
        self.ignoredReadings = ignoredReadings
    }
}

/// What the Recorder must do, in order.
public enum RecorderAction: Equatable, Sendable {
    /// Stage 1: create the ride row (`recording`), location on, `Notifier.rideStarted()`
    case rideStarted(seq: Int, startT: Double, manual: Bool)
    case rideConfirmed(seq: Int, at: Double, by: RideConfirmSignal)
    /// Silent cancel: delete the ride row (samples, chunks, gaps go with it)
    case rideCancelled(seq: Int)
    /// A batch of samples (t = seconds from the ride start)
    case samples(seq: Int, [RecorderSample])
    /// Raw scooter packets of the last ~30 s (`RecorderRaw.pack`; the app compresses with zlib)
    case rawChunk(seq: Int, startT: Double, endT: Double, blob: Data)
    /// Phone mode started (gap row, kind scooter, from `startT`)
    case gapOpened(seq: Int, startT: Double, reason: PhoneModeReason)
    case gapClosed(seq: Int, endT: Double)
    case progress(RecorderProgress)
    case sameRideOffered(seq: Int, previousSeq: Int)
    case rideMerged(seq: Int, intoSeq: Int)
    case batteryRanOut(seq: Int, pct: Int)
    /// Close the ride row (end, totals from the stored samples, stops, gaps, walking stretches)
    case rideEnded(RecorderClose)
    /// Save this (JSON) for recovery after a crash or an iOS kill
    case snapshot(RecorderSnapshot)
    /// Once a second: what the live view shows
    case live(LiveInput, LiveState)
    /// `Notifier.shared.rideActive`
    case rideActive(Bool)
}

/// The Recorder's saved state: the engine (JSON-restorable, M1-04) plus the open ride's sampling state.
public struct RecorderSnapshot: Codable, Equatable, Sendable {
    public var engine: RideEngine
    public var seq: Int?
    public var startT: Double?
    public var topSpeedKmh: Double
    public var ignoredAtStart: Int
    /// Newest sample time of the open ride (absolute), for `RideRecovery.decide`
    public var lastSampleT: Double?
}

/// Raw packet chunk format v1 (before zlib): per packet a little-endian UInt32 of ms since the chunk start,
/// one length byte, then the bytes.
public enum RecorderRaw {
    public static func pack(_ packets: [(t: Double, bytes: [UInt8])], startT: Double) -> Data {
        var d = Data()
        for p in packets {
            let ms = UInt32(clamping: Int(((p.t - startT) * 1000).rounded()))
            withUnsafeBytes(of: ms.littleEndian) { d.append(contentsOf: $0) }
            d.append(UInt8(clamping: p.bytes.count))
            d.append(contentsOf: p.bytes.prefix(255))
        }
        return d
    }

    public static func unpack(_ d: Data, startT: Double) -> [(t: Double, bytes: [UInt8])] {
        let b = [UInt8](d)
        var out: [(t: Double, bytes: [UInt8])] = []
        var i = 0
        while i + 5 <= b.count {
            let ms = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            let n = Int(b[i + 4])
            i += 5
            guard i + n <= b.count else { break }
            out.append((t: startT + Double(ms) / 1000, bytes: Array(b[i..<i + n])))
            i += n
        }
        return out
    }
}

public struct RideRecorderCore {
    public static let sampleIntervalS = 5.0
    /// Samples, raw chunk and ride row are written every 30 s (ARCHITECTURE §5)
    public static let flushIntervalS = 30.0
    /// The engine state is saved every 5 s (≤ 5 s lost after a kill, SC-14)
    public static let snapshotIntervalS = 5.0

    public private(set) var feed: RideFeed
    public private(set) var lastLive: LiveState?
    var builder = LiveStateBuilder()
    var sampler: RideSampler?
    public private(set) var seq: Int?
    public private(set) var startT = 0.0
    public private(set) var topSpeedKmh = 0.0
    var ignoredAtStart = 0
    var pending: [RecorderSample] = []
    var raw: [(t: Double, bytes: [UInt8])] = []
    var rawStartT: Double?
    var lastFlushT = 0.0
    var lastSnapshotT = -Double.infinity
    var lastLiveT = -Double.infinity
    public private(set) var lastSampleT: Double?
    var wasActive = false

    public init(engine: RideEngine = RideEngine()) {
        feed = RideFeed(engine: engine)
    }

    public var engine: RideEngine { feed.engine }

    /// Decision 5: the usual %/km for "~N% est." (median of the last 10 rides, set by the app)
    public mutating func setUsualPctPerKm(_ v: Double?) {
        feed.engine.usualPctPerKm = v
    }

    // MARK: Inputs

    public mutating func scooter(_ e: TimedScooterEvent) -> [RecorderAction] {
        var out: [RecorderAction] = []
        take(feed.scooter(e), at: e.t, &out)
        if case .packet(let bytes) = e.event, seq != nil {
            if rawStartT == nil { rawStartT = e.t }
            raw.append((t: e.t, bytes: bytes))
        }
        if let f = feed.lastNewFrame, seq != nil, var s = sampler {
            if let v = f.speedKmh { topSpeedKmh = max(topSpeedKmh, v) }
            if let sample = s.offer(f, startT: startT) {
                pending.append(RecorderSample(sample: sample, mode: mode(of: sample)))
                lastSampleT = f.t
            }
            sampler = s
        }
        periodic(at: e.t, &out)
        return out
    }

    public mutating func fix(_ f: PhoneFix) -> [RecorderAction] {
        var out: [RecorderAction] = []
        take(feed.fix(f), at: f.t, &out)
        if seq != nil, feed.engine.phoneMode(at: f.t), var s = sampler {
            // phone mode: GPS-only samples keep the path going (no scooter fields, no energy)
            if let sample = s.offer(fix: f, startT: startT) {
                pending.append(RecorderSample(sample: sample, mode: "phone"))
                lastSampleT = f.t
            }
            sampler = s
        } else {
            sampler?.update(fix: f)
        }
        periodic(at: f.t, &out)
        return out
    }

    public mutating func baro(_ b: BaroReading) -> [RecorderAction] {
        sampler?.update(baro: b)
        return []
    }

    /// Buttons and answers (Start ride, Not riding, hold to end, Same ride?)
    public mutating func press(_ input: RideEngineInput, at t: Double) -> [RecorderAction] {
        var out: [RecorderAction] = []
        take(feed.input(input, at: t), at: t, &out)
        periodic(at: t, &out)
        return out
    }

    /// About once a second: the engine's timeouts, the live view, the timers.
    public mutating func tick(at t: Double) -> [RecorderAction] {
        var out: [RecorderAction] = []
        take(feed.input(.tick, at: t), at: t, &out)
        if t - lastLiveT >= 0.999 {
            lastLiveT = t
            let input = feed.engine.liveInput(at: t)
            let state = builder.update(input)
            lastLive = state
            out.append(.live(input, state))
        }
        periodic(at: t, &out)
        return out
    }

    // MARK: Engine events → actions

    private func mode(of s: RideSample) -> String {
        if s.speedKmh == nil, s.voltage == nil { return "phone" }
        if feed.engine.ride?.walks.last?.isOpen == true { return "walk" }
        return "scooter"
    }

    private mutating func take(_ events: [RideEngineEvent], at t: Double, _ out: inout [RecorderAction]) {
        for e in events {
            switch e {
            case let .rideStarted(s, at, manual):
                seq = s
                startT = at
                sampler = RideSampler(intervalS: Self.sampleIntervalS)
                topSpeedKmh = 0
                ignoredAtStart = feed.pipeline.plausibility.ignoredReadings
                pending = []
                raw = []
                rawStartT = nil
                lastFlushT = at
                lastSampleT = nil
                out.append(.rideStarted(seq: s, startT: at, manual: manual))
                lastSnapshotT = -Double.infinity
            case let .rideConfirmed(s, at, by):
                out.append(.rideConfirmed(seq: s, at: at, by: by))
            case let .rideCancelled(s, _, _):
                clearRide()
                out.append(.rideCancelled(seq: s))
                out.append(.snapshot(snapshot()))
                lastSnapshotT = t
            case let .phoneModeStarted(s, at, reason):
                out.append(.gapOpened(seq: s, startT: at, reason: reason))
            case let .phoneModeEnded(s, at):
                out.append(.gapClosed(seq: s, endT: at))
            case let .sameRideOffered(s, p):
                out.append(.sameRideOffered(seq: s, previousSeq: p))
            case let .rideMerged(s, into):
                out.append(.rideMerged(seq: s, intoSeq: into))
            case .walkStarted:
                break
            case let .batteryRanOut(s, pct):
                out.append(.batteryRanOut(seq: s, pct: pct))
            case let .rideEnded(end):
                flush(at: t, &out)
                let ignored = max(0, feed.pipeline.plausibility.ignoredReadings - ignoredAtStart)
                out.append(.rideEnded(RecorderClose(end: end, topSpeedKmh: topSpeedKmh, ignoredReadings: ignored)))
                clearRide()
                out.append(.snapshot(snapshot()))
                lastSnapshotT = t
            }
        }
        let active = feed.engine.rideActive
        if active != wasActive {
            wasActive = active
            out.append(.rideActive(active))
        }
    }

    private mutating func clearRide() {
        seq = nil
        sampler = nil
        pending = []
        raw = []
        rawStartT = nil
        topSpeedKmh = 0
        lastSampleT = nil
    }

    private mutating func flush(at t: Double, _ out: inout [RecorderAction]) {
        guard let s = seq else { return }
        if !pending.isEmpty {
            out.append(.samples(seq: s, pending))
            pending = []
        }
        if let r0 = rawStartT, !raw.isEmpty {
            let end = raw.last?.t ?? r0
            out.append(.rawChunk(seq: s, startT: r0, endT: end, blob: RecorderRaw.pack(raw, startT: r0)))
            raw = []
            rawStartT = nil
        }
        if let r = feed.engine.ride, r.seq == s {
            out.append(.progress(RecorderProgress(seq: s, odoStartKm: r.odoTrimKm ?? r.odoStartKm, odoLastKm: r.odoLastKm,
                                                  distanceM: r.distanceAfterTrimM, firstMoveT: r.firstMoveT, lastMoveT: r.lastMoveT,
                                                  topSpeedKmh: topSpeedKmh, lastBatteryPct: r.lastBatteryPct)))
        }
        lastFlushT = t
    }

    private mutating func periodic(at t: Double, _ out: inout [RecorderAction]) {
        guard seq != nil else { return }
        if t - lastFlushT >= Self.flushIntervalS { flush(at: t, &out) }
        if t - lastSnapshotT >= Self.snapshotIntervalS {
            out.append(.snapshot(snapshot()))
            lastSnapshotT = t
        }
    }

    /// Everything written so far is in the actions; call when the app goes to the background or stops.
    public mutating func flushNow(at t: Double) -> [RecorderAction] {
        var out: [RecorderAction] = []
        flush(at: t, &out)
        out.append(.snapshot(snapshot()))
        lastSnapshotT = t
        return out
    }

    // MARK: Recovery (SC-14)

    public func snapshot() -> RecorderSnapshot {
        RecorderSnapshot(engine: feed.engine, seq: seq, startT: seq != nil ? startT : nil, topSpeedKmh: topSpeedKmh,
                         ignoredAtStart: ignoredAtStart, lastSampleT: lastSampleT)
    }

    /// At launch, from the last saved snapshot: what recovery decided (M2 "Recovery") and the core to go on with.
    /// `lastDataT` = the open ride's newest stored sample (absolute time), if any.
    public static func restore(_ snap: RecorderSnapshot, lastDataT: Double?, now: Double) -> (core: RideRecorderCore, decision: RideRecovery.Decision) {
        let last = [lastDataT, snap.lastSampleT].compactMap { $0 }.max()
        let decision = RideRecovery.decide(snapshot: snap.engine, lastDataT: last, now: now)
        var engine = snap.engine
        switch decision {
        case .resume:
            engine.relaunched(at: now)
            var core = RideRecorderCore(engine: engine)
            if let s = snap.seq, let st = snap.startT, engine.ride?.seq == s {
                core.seq = s
                core.startT = st
                core.sampler = RideSampler(intervalS: sampleIntervalS)
                core.topSpeedKmh = snap.topSpeedKmh
                core.lastFlushT = now
                core.lastSampleT = last
                core.wasActive = engine.rideActive
            }
            return (core, decision)
        case .nothingOpen:
            engine.relaunched(at: now)
            return (RideRecorderCore(engine: engine), decision)
        case .endRecovered, .discard:
            engine.dropOpenRide()
            engine.relaunched(at: now)
            return (RideRecorderCore(engine: engine), decision)
        }
    }
}

/// One input to the Recorder, on the caller's clock (the app feeds these from the scooter link, the phone sensors,
/// the buttons and a 1-s timer; the simulator from a stream).
public enum RecorderInput: Equatable, Sendable {
    case scooter(TimedScooterEvent)
    case fix(PhoneFix)
    case baro(BaroReading)
    case press(RideEngineInput)
    case tick
}

extension RideRecorderCore {
    public mutating func handle(_ input: RecorderInput, at t: Double) -> [RecorderAction] {
        switch input {
        case .scooter(let e): return scooter(e)
        case .fix(let f): return fix(f)
        case .baro(let b): return baro(b)
        case .press(let p): return press(p, at: t)
        case .tick: return tick(at: t)
        }
    }
}
