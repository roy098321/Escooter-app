import Foundation

/// B25 (T-04): what the ride close writes back onto every stored sample: moving (the engine's flag, or the speed rule),
/// the stop it lies in, and the cumulative distance (M5: the odometer series; GPS for a ride without odometer). The same
/// rules as the ride metrics, so the columns agree with the totals.
public struct SampleAnnotation: Equatable, Sendable {
    /// Seconds from the ride start (the sample's `t`)
    public var t: Double
    public var moving: Bool
    /// Index into the stop list given (nil = not in a stop)
    public var stopIndex: Int?
    /// Cumulative from the ride start, m
    public var distanceM: Double
}

public enum SampleAnnotator {
    /// `samples` may carry the engine's `moving` flags (nil = derived from the speed, M3 hysteresis); `stops` in seconds from the start.
    public static func annotate(_ input: [RideSample], stops: [RideStopSpan], wheelFactor: Double = 1.0) -> [SampleAnnotation] {
        let samples = input.sorted { $0.t < $1.t }
        guard !samples.isEmpty else { return [] }
        let moving = RideMetricsCalculator.movingFlags(samples)
        let distance = samples.contains { $0.odometerKm != nil }
            ? RideMetricsCalculator.distanceSeries(samples, wheelFactor: wheelFactor)
            : gpsSeries(samples)
        return samples.indices.map { i in
            let t = samples[i].t
            let stop = stops.firstIndex { t >= $0.startT && t <= ($0.endT ?? .infinity) }
            return SampleAnnotation(t: t, moving: moving[i] && stop == nil, stopIndex: stop, distanceM: distance[i])
        }
    }

    /// Cumulative GPS distance over good fixes (phone-only rides), m.
    static func gpsSeries(_ samples: [RideSample]) -> [Double] {
        var out: [Double] = []
        var total = 0.0
        var last: RideSample?
        for s in samples {
            if s.hasGoodFix {
                if let l = last { total += RideMetricsCalculator.meters(l, s) }
                last = s
            }
            out.append(total)
        }
        return out
    }
}

extension RideEnd {
    /// B25: the annotations of a closed ride's stored samples with the engine's flags (false before the walking trim and after
    /// the last movement, in a stop, in a walking stretch); `stopIndex` points into `ride.stops`.
    public func sampleAnnotations(_ samples: [RideSample], wheelFactor: Double = 1.0) -> [SampleAnnotation] {
        let s0 = ride.startT
        let stops = ride.stops.map { RideStopSpan(startT: $0.startT - s0, endT: $0.endT.map { $0 - s0 }) }
        let flagged = metricsInput(samples).samples
        var flags: [Double: Bool] = [:]
        for s in flagged { flags[s.t] = s.moving }
        let all = samples.map { s -> RideSample in
            var x = s
            x.moving = flags[s.t] ?? (ride.trimStartT == nil ? nil : false)
            return x
        }
        return SampleAnnotator.annotate(all, stops: stops, wheelFactor: wheelFactor)
    }
}
