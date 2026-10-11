import Foundation

/// M5-02: trim start / end. The window is in seconds from the ride start (the same clock as the stored samples).
public enum RideTrim {
    /// A trimmed ride must keep at least this much
    public static let minLengthS = 60.0

    /// Puts a wanted window inside the ride and at least `minLengthS` long. nil: the ride is too short to trim.
    public static func clamp(startS: Double, endS: Double, lastS: Double) -> (start: Double, end: Double)? {
        guard lastS >= minLengthS else { return nil }
        var s = min(max(0, startS), lastS - minLengthS)
        var e = min(max(endS, minLengthS), lastS)
        if e - s < minLengthS {
            if startS > endS - minLengthS { s = max(0, e - minLengthS) } else { e = min(lastS, s + minLengthS) }
        }
        return (s, e)
    }

    /// The samples inside the window, plus the last one before it as the odometer anchor (not moving).
    public static func window(_ input: [RideSample], startS: Double, endS: Double) -> [RideSample] {
        let samples = input.sorted { $0.t < $1.t }
        let anchor = samples.lastIndex { $0.t <= startS }
        var out: [RideSample] = []
        for (i, sample) in samples.enumerated() {
            if sample.t > endS { break }
            if let anchor, i < anchor { continue }
            var s = sample
            if s.t < startS { s.moving = false }
            out.append(s)
        }
        return out
    }

    /// The spans cut to the window; spans outside it are dropped.
    public static func clip(_ spans: [RideStopSpan], startS: Double, endS: Double) -> [RideStopSpan] {
        var out: [RideStopSpan] = []
        for span in spans {
            let a = max(span.startT, startS)
            let b = min(span.endT ?? endS, endS)
            if b > a { out.append(RideStopSpan(startT: a, endT: b)) }
        }
        return out
    }
}

/// M5-02: the one place that recomputes a ride's numbers after a merge or a trim.
public enum RideRecompute {
    /// - Parameters:
    ///   - stops: stops inside the ride, including the bridges.
    ///   - bridges: pauses bridged by a merge (a stop with no samples in it): they count as a stop and as time, not as missing scooter data.
    ///   - trimStartS / trimEndS: the trim window; nil = the whole ride.
    public static func metrics(samples: [RideSample], stops: [RideStopSpan], walks: [RideStopSpan], bridges: [RideStopSpan] = [],
                               ignoredReadings: Int = 0, trimStartS: Double? = nil, trimEndS: Double? = nil) -> RideMetrics {
        var used = samples
        var usedStops = stops
        var usedWalks = walks
        var usedBridges = bridges
        if let s = trimStartS, let e = trimEndS {
            used = RideTrim.window(samples, startS: s, endS: e)
            usedStops = RideTrim.clip(stops, startS: s, endS: e)
            usedWalks = RideTrim.clip(walks, startS: s, endS: e)
            usedBridges = RideTrim.clip(bridges, startS: s, endS: e)
        }
        var m = RideMetricsCalculator.compute(used, stops: usedStops, walks: usedWalks, ignoredReadings: ignoredReadings)
        var bridgeS = 0.0
        for b in usedBridges { bridgeS += (b.endT ?? b.startT) - b.startT }
        m.gapScooterS = max(0, m.gapScooterS - bridgeS)
        return m
    }
}
