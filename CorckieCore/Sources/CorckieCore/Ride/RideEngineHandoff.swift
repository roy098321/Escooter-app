import Foundation

// M1-04 hand-off points for the Recorder (M1-09): recovery after a relaunch or crash, and the stored
// ride rows → ride metrics (M1-06) with the engine's moving flag, stop rows and walking stretches.

/// CALC_SPEC M2 "Recovery": on launch, a ride still `recording` with no data for > 2 min is ended at its
/// last sample (`status = recovered`); a younger one resumes from the saved engine state.
public enum RideRecovery {
    public static let maxSilenceS = 120.0

    public enum Decision: Equatable, Sendable {
        /// No ride was open
        case nothingOpen
        /// Keep going: call `relaunched(at:)` on the restored state and feed it again
        case resume
        /// Close the ride row with this (reason `recovered`, status `recovered`)
        case endRecovered(RideEnd)
        /// The ride was never confirmed: delete it, as a silent cancel would have
        case discard(seq: Int, at: Double)
    }

    /// - Parameters:
    ///   - snapshot: the engine state the Recorder saved last (JSON, every few seconds)
    ///   - lastDataT: time of the ride's newest stored sample, if any
    ///   - now: launch time, same clock
    public static func decide(snapshot: RideEngine, lastDataT: Double?, now: Double) -> Decision {
        guard let ride = snapshot.ride else { return .nothingOpen }
        let last = max(lastDataT ?? snapshot.now, snapshot.now)
        if now - last <= maxSilenceS { return .resume }
        guard ride.confirmed else { return .discard(seq: ride.seq, at: last) }
        guard let end = snapshot.closing(.recovered, at: last) else { return .nothingOpen }
        return .endRecovered(end)
    }
}

extension RideEnd {
    /// What `RideMetricsCalculator.compute` needs from the stored samples (t = seconds from the ride start):
    /// the samples from the walking trim on, each with the engine's `moving` flag (false in a stop, in a
    /// walking stretch, before the trim and after the last movement), the stop rows and the walking stretches.
    public func metricsInput(_ samples: [RideSample]) -> (samples: [RideSample], stops: [RideStopSpan], walks: [RideStopSpan]) {
        let s0 = ride.startT
        let stops = ride.stops.map { RideStopSpan(startT: $0.startT - s0, endT: $0.endT.map { $0 - s0 }) }
        let walks = ride.walks.map { RideStopSpan(startT: $0.startT - s0, endT: $0.endT.map { $0 - s0 }) }
        guard let trim = ride.trimStartT else { return ([], stops, walks) }
        let trimRel = trim - s0
        let endRel = endT - s0
        let sorted = samples.sorted { $0.t < $1.t }
        // keep the last sample at or before the trim as the odometer anchor
        let firstIndex = sorted.lastIndex { $0.t <= trimRel } ?? 0
        func inside(_ t: Double, _ spans: [RideStopSpan]) -> Bool {
            spans.contains { t >= $0.startT && t <= ($0.endT ?? .infinity) }
        }
        var out: [RideSample] = []
        for var s in sorted.dropFirst(firstIndex) {
            s.moving = s.t >= trimRel && s.t <= endRel && !inside(s.t, stops) && !inside(s.t, walks)
            out.append(s)
        }
        return (out, stops, walks)
    }

    /// The ride numbers from the stored samples (M1-06) with the engine's flags.
    public func metrics(_ samples: [RideSample], ignoredReadings: Int = 0, wheelFactor: Double = 1.0) -> RideMetrics {
        let input = metricsInput(samples)
        return RideMetricsCalculator.compute(input.samples, stops: input.stops, walks: input.walks,
                                             ignoredReadings: ignoredReadings, wheelFactor: wheelFactor)
    }
}

extension RideSizeClass {
    /// M36 re-checked after "Same ride": the pieces of one merge group count together.
    public static func of(groupDistancesM: [Double]) -> RideSizeClass {
        of(distanceM: groupDistancesM.reduce(0, +))
    }
}
