import CorckieCore
import Foundation

/// Plays a scooter + phone stream through the real ride engine on a virtual clock, with a tick every
/// second (as the Recorder does), and keeps the samples the Recorder would store (`RideSampler`, 5 s).
/// Used by the scenario tests and the in-app checks u9 / u10, so both test the same path.
public enum EngineRunner {
    public struct Result {
        public var events: [(t: Double, event: RideEngineEvent)] = []
        public var ends: [RideEnd] = []
        /// Samples per ride seq, t from the ride start (what `ride_sample` would hold)
        public var samples: [Int: [RideSample]] = [:]
        public var engine = RideEngine()
        /// What recovery decided at each relaunch
        public var recoveries: [RideRecovery.Decision] = []

        public var started: [(seq: Int, at: Double, manual: Bool)] {
            events.compactMap { item -> (seq: Int, at: Double, manual: Bool)? in
                if case let .rideStarted(s, a, m) = item.event { return (seq: s, at: a, manual: m) }
                return nil
            }
        }
        public var confirmed: [(seq: Int, at: Double, by: RideConfirmSignal)] {
            events.compactMap { item -> (seq: Int, at: Double, by: RideConfirmSignal)? in
                if case let .rideConfirmed(s, a, b) = item.event { return (seq: s, at: a, by: b) }
                return nil
            }
        }
        public var cancelled: [(seq: Int, at: Double, reason: RideCancelReason)] {
            events.compactMap { item -> (seq: Int, at: Double, reason: RideCancelReason)? in
                if case let .rideCancelled(s, a, r) = item.event { return (seq: s, at: a, reason: r) }
                return nil
            }
        }
        public var sameRideOffers: [(seq: Int, previousSeq: Int)] {
            events.compactMap { item -> (seq: Int, previousSeq: Int)? in
                if case let .sameRideOffered(s, p) = item.event { return (seq: s, previousSeq: p) }
                return nil
            }
        }
        public var batteryRanOut: [(seq: Int, pct: Int)] {
            events.compactMap { item -> (seq: Int, pct: Int)? in
                if case let .batteryRanOut(s, p) = item.event { return (seq: s, pct: p) }
                return nil
            }
        }
    }

    /// A scripted button press or answer at a time.
    public struct Press {
        public var t: Double
        public var input: RideEngineInput
        public init(t: Double, _ input: RideEngineInput) {
            self.t = t
            self.input = input
        }
    }

    private enum Item {
        case scooter(TimedScooterEvent)
        case phone(TimedPhoneEvent)
        case press(Press)
        var t: Double {
            switch self {
            case .scooter(let e): return e.t
            case .phone(let e): return e.t
            case .press(let p): return p.t
            }
        }
    }

    /// - Parameters:
    ///   - tailS: ticks keep coming this long after the last event (the end rules need time)
    ///   - relaunchAt: the app is killed here; the engine state goes through JSON (as the Recorder stores it),
    ///     recovery decides, and the app is back `relaunchGapS` later, with every event in between lost (SC-14)
    ///   - answerSameRide: answer every "Same ride?" offer at once with this (nil = never answer)
    public static func run(_ stream: SimStream, presses: [Press] = [], tailS: Double = 300,
                           relaunchAt: Double? = nil, relaunchGapS: Double = 3, answerSameRide: Bool? = nil,
                           sampleIntervalS: Double = 5) -> Result {
        var items = stream.scooter.map { Item.scooter($0) } + stream.phone.map { Item.phone($0) } + presses.map { Item.press($0) }
        items = items.enumerated().sorted { a, b in a.element.t == b.element.t ? a.offset < b.offset : a.element.t < b.element.t }
            .map(\.element)
        var result = Result()
        guard let firstT = items.first?.t else { return result }
        var feed = RideFeed()
        var sampler: RideSampler?
        var startT = 0.0
        var nextTick = firstT.rounded(.down) + 1
        var relaunchPending = relaunchAt
        var skipUntil = -Double.infinity
        var lastSampleAbsT: Double?

        func take(_ events: [RideEngineEvent], at t: Double) {
            for e in events {
                result.events.append((t, e))
                switch e {
                case let .rideStarted(seq, at, _):
                    sampler = RideSampler(intervalS: sampleIntervalS)
                    startT = at
                    result.samples[seq] = []
                case let .rideCancelled(seq, _, _):
                    sampler = nil
                    result.samples[seq] = nil
                case let .rideEnded(end):
                    sampler = nil
                    result.ends.append(end)
                case .sameRideOffered:
                    if let yes = answerSameRide { take(feed.input(.sameRideAnswer(yes), at: t), at: t) }
                default:
                    break
                }
            }
        }

        func tick(until t: Double) {
            while nextTick < t {
                take(feed.input(.tick, at: nextTick), at: nextTick)
                nextTick += 1
            }
        }

        func relaunch(at t: Double) {
            let data = try? JSONEncoder().encode(feed.engine)
            var restored = data.flatMap { try? JSONDecoder().decode(RideEngine.self, from: $0) } ?? RideEngine()
            let back = t + relaunchGapS
            let decision = RideRecovery.decide(snapshot: restored, lastDataT: lastSampleAbsT, now: back)
            result.recoveries.append(decision)
            switch decision {
            case .nothingOpen, .resume:
                restored.relaunched(at: back)
            case .endRecovered(let end):
                restored.dropOpenRide()
                restored.relaunched(at: back)
                take([.rideEnded(end)], at: back)
            case let .discard(seq, at):
                restored.dropOpenRide()
                restored.relaunched(at: back)
                take([.rideCancelled(seq: seq, at: at, reason: .unconfirmed)], at: back)
            }
            feed = RideFeed(engine: restored)
            if decision != .resume { sampler = nil }
            skipUntil = back
            nextTick = back.rounded(.down) + 1
        }

        for item in items {
            if let r = relaunchPending, item.t >= r {
                tick(until: r)
                relaunch(at: r)
                relaunchPending = nil
            }
            if item.t < skipUntil { continue }
            tick(until: item.t)
            switch item {
            case .scooter(let e):
                take(feed.scooter(e), at: e.t)
                if let f = feed.lastNewFrame, feed.engine.rideActive, var s = sampler {
                    if let sample = s.offer(f, startT: startT) {
                        result.samples[feed.engine.ride?.seq ?? 0, default: []].append(sample)
                        lastSampleAbsT = f.t
                    }
                    sampler = s
                }
            case .phone(let e):
                switch e.event {
                case .fix(let f):
                    take(feed.fix(f), at: e.t)
                    sampler?.update(fix: f)
                case .baro(let b):
                    sampler?.update(baro: b)
                default:
                    break
                }
            case .press(let p):
                take(feed.input(p.input, at: p.t), at: p.t)
            }
        }
        let lastT = items.last?.t ?? firstT
        tick(until: lastT + tailS)
        result.engine = feed.engine
        return result
    }
}
