import Foundation

/// B59 (owner 22 Oct): the ride route is ONE line per unbroken run with a colour per point along it (uniform width, nothing
/// overlapping), instead of many short coloured pieces with round caps that showed blobs at every join. The app strokes each run as
/// one map polyline with a gradient whose stops sit at each stretch's position along the run. Pure, so it is tested on Linux.

public struct GradientStop: Equatable, Sendable {
    /// 0...1 along the run (by distance)
    public var location: Double
    public var r: Double
    public var g: Double
    public var b: Double

    public init(location: Double, r: Double, g: Double, b: Double) {
        self.location = location
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct GradientRun: Equatable, Sendable {
    public var coords: [GeoPoint]
    public var stops: [GradientStop]

    public init(coords: [GeoPoint], stops: [GradientStop]) {
        self.coords = coords
        self.stops = stops
    }
}

public enum GradientLine {
    /// At most this many colour stops per run (a long ride stays light to draw)
    public static let maxStops = 160

    /// Joined stretches (each one starts where the last ended) become one run; a break (a gap in the fixes) starts a new run.
    public static func runs(_ stretches: [ValueStretch], ramp: GradientRamp) -> [GradientRun] {
        var groups: [[ValueStretch]] = []
        for s in stretches {
            if let last = groups.last?.last, last.b == s.a {
                groups[groups.count - 1].append(s)
            } else {
                groups.append([s])
            }
        }
        return groups.compactMap { run(of: $0, ramp: ramp) }
    }

    static func run(of group: [ValueStretch], ramp: GradientRamp) -> GradientRun? {
        guard let first = group.first else { return nil }
        var coords = [first.a]
        var mids: [(dist: Double, value: Double)] = []
        var total = 0.0
        for s in group {
            let d = Geo.distanceM(s.a, s.b)
            mids.append((total + d / 2, s.value))
            total += d
            coords.append(s.b)
        }
        guard total > 0 else { return nil }
        // thin the stops evenly (always the first and the last)
        var picked = mids
        if mids.count > maxStops {
            let step = Double(mids.count - 1) / Double(maxStops - 1)
            picked = (0..<maxStops).map { mids[Int((Double($0) * step).rounded())] }
        }
        var stops: [GradientStop] = []
        func add(_ location: Double, _ value: Double) {
            let c = ramp.rgb(at: value)
            stops.append(GradientStop(location: min(1, max(0, location)), r: c.r, g: c.g, b: c.b))
        }
        add(0, picked[0].value)
        for m in picked { add(m.dist / total, m.value) }
        add(1, picked[picked.count - 1].value)
        // locations never go backwards
        for i in 1..<stops.count where stops[i].location < stops[i - 1].location { stops[i].location = stops[i - 1].location }
        return GradientRun(coords: coords, stops: stops)
    }
}
