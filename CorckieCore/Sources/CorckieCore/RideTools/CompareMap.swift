import Foundation

// F-05: two rides on one map. Pure maths for the shared map, the tap read-out and the synced playback. The time difference is
// aligned **by distance along the path** (each point of ride A is projected onto ride B's line, moving only forward), never by
// the clock, so a red light shows up as the difference growing at that spot. It is a comparison tool, not a race: no winner,
// no scores, no badges (P-3). Reads stored samples only.

/// One stored position of a ride with its time from the ride start.
public struct ComparePoint: Equatable, Sendable {
    /// seconds from the ride's first position
    public var t: Double
    public var lat: Double
    public var lon: Double
    /// cumulative distance along the path, m
    public var distM: Double
    public var speedKmh: Double?

    public init(t: Double, lat: Double, lon: Double, distM: Double = 0, speedKmh: Double? = nil) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.distM = distM
        self.speedKmh = speedKmh
    }
}

/// What the tap read-out shows for one ride
public struct CompareReadout: Equatable, Sendable {
    /// seconds from the ride start at the tapped spot
    public var timeS: Double
    public var speedKmh: Double?
    /// how far the tap was from the ride's line, m
    public var offsetM: Double
}

public struct ComparePath: Equatable, Sendable {
    public private(set) var points: [ComparePoint]

    /// Fixes worse than this are left out of the line
    public static let maxHAccM = 50.0

    public init(points: [ComparePoint]) {
        self.points = points
    }

    public var isEmpty: Bool { points.count < 2 }
    public var durationS: Double { points.last?.t ?? 0 }
    public var lengthM: Double { points.last?.distM ?? 0 }

    /// From the ride's stored points (the same `RidePoint` the ride detail draws): only good fixes, time and distance from the first one.
    public static func build(_ input: [RidePoint]) -> ComparePath {
        let sorted = input.sorted { $0.t < $1.t }
        var out: [ComparePoint] = []
        var t0: Int64?
        for p in sorted {
            guard let lat = p.lat, let lon = p.lon else { continue }
            if let h = p.hAccM, h > maxHAccM { continue }
            let start = t0 ?? p.t
            t0 = start
            let dist: Double
            if let last = out.last {
                dist = last.distM + Geo.distanceM(GeoPoint(lat: last.lat, lon: last.lon), GeoPoint(lat: lat, lon: lon))
            } else {
                dist = 0
            }
            out.append(ComparePoint(t: Double(p.t - start) / 1000, lat: lat, lon: lon, distM: dist, speedKmh: p.speedKmh ?? p.gpsSpeedKmh))
        }
        return ComparePath(points: out)
    }

    // MARK: position and time

    /// The position at a time from the start (held at the first / last point outside the ride); nil for an empty path.
    public func position(atTime t: Double) -> ComparePoint? {
        guard let first = points.first, let last = points.last else { return nil }
        if t <= first.t { return first }
        if t >= last.t { return last }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        let speed: Double? = (a.speedKmh != nil && b.speedKmh != nil) ? a.speedKmh! + (b.speedKmh! - a.speedKmh!) * f : a.speedKmh ?? b.speedKmh
        return ComparePoint(t: t, lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f, distM: a.distM + (b.distM - a.distM) * f, speedKmh: speed)
    }

    /// The same path moved sideways by `metres` (positive = to the right of the direction of travel), so two rides on the same road
    /// are drawn side by side instead of one on top of the other.
    public func offset(byM metres: Double) -> ComparePath {
        guard points.count >= 2, metres != 0 else { return self }
        var out = points
        for i in points.indices {
            let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
            let cosLat = cos(points[i].lat * .pi / 180)
            let dx = (b.lon - a.lon) * cosLat * Geo.mPerDegLat      // east, m
            let dy = (b.lat - a.lat) * Geo.mPerDegLat               // north, m
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { continue }
            // right-hand normal of (dx, dy) is (dy, -dx)
            let nx = dy / len, ny = -dx / len
            out[i].lat += ny * metres / Geo.mPerDegLat
            out[i].lon += nx * metres / (Geo.mPerDegLat * max(cosLat, 0.01))
        }
        return ComparePath(points: out)
    }

    // MARK: nearest point (tap)

    /// The ride's time and speed at the spot nearest to a tapped coordinate, or nil when the tap is further than `maxOffsetM` from the line.
    public func readout(nearLat lat: Double, lon: Double, maxOffsetM: Double = 60) -> CompareReadout? {
        guard points.count >= 2 else { return nil }
        let frame = LocalFrame(lat: lat, lon: lon)
        var best: (offset: Double, index: Int, f: Double)?
        for i in 0..<(points.count - 1) {
            let (d, f) = frame.distanceToSegment(points[i], points[i + 1])
            if best == nil || d < best!.offset { best = (d, i, f) }
        }
        guard let b = best, b.offset <= maxOffsetM else { return nil }
        let a = points[b.index], c = points[b.index + 1]
        let t = a.t + (c.t - a.t) * b.f
        let speed: Double? = (a.speedKmh != nil && c.speedKmh != nil) ? a.speedKmh! + (c.speedKmh! - a.speedKmh!) * b.f : a.speedKmh ?? c.speedKmh
        return CompareReadout(timeS: t, speedKmh: speed, offsetM: b.offset)
    }
}

/// Metres east / north of a reference point (flat-earth, fine over a city)
struct LocalFrame {
    let lat: Double
    let lon: Double
    let cosLat: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
        self.cosLat = cos(lat * .pi / 180)
    }

    func xy(_ p: ComparePoint) -> (x: Double, y: Double) {
        ((p.lon - lon) * cosLat * Geo.mPerDegLat, (p.lat - lat) * Geo.mPerDegLat)
    }

    /// Distance from the frame's origin to the segment ab, and the position along it (0...1)
    func distanceToSegment(_ a: ComparePoint, _ b: ComparePoint) -> (Double, Double) {
        let pa = xy(a), pb = xy(b)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let len2 = dx * dx + dy * dy
        var f = 0.0
        if len2 > 0 { f = min(1, max(0, -(pa.x * dx + pa.y * dy) / len2)) }
        let px = pa.x + dx * f, py = pa.y + dy * f
        return ((px * px + py * py).squareRoot(), f)
    }
}

/// Where ride A's point i sits on ride B and when ride B was there.
public struct CompareMatch: Equatable, Sendable {
    public var timeA: Double
    public var timeB: Double
    /// B minus A, seconds: positive = ride B reached this spot later
    public var deltaS: Double { timeB - timeA }
    /// distance between the two lines here, m
    public var offsetM: Double
}

public enum CompareAlign {
    /// A point further than this from the other ride's line has no match (the rides took different roads there)
    public static let maxOffsetM = 60.0
    /// How far apart (along the path) matched spots may be: 150 m + 30 % of the distance so far, so a loop's start never matches its end
    public static func toleranceM(_ distM: Double) -> Double { 150 + 0.3 * distM }

    /// One entry per point of A: its match on B, or nil where B was not on the same road. Only moves forward along B.
    public static func match(_ a: ComparePath, _ b: ComparePath) -> [CompareMatch?] {
        guard !a.isEmpty, !b.isEmpty else { return a.points.map { _ in nil } }
        var out: [CompareMatch?] = []
        var lowSeg = 0                     // B segment index the search starts from (never goes back)
        let window = 400
        for p in a.points {
            let frame = LocalFrame(lat: p.lat, lon: p.lon)
            let tol = toleranceM(p.distM)
            var best: (d: Double, j: Int, f: Double)?
            var j = lowSeg
            let end = min(b.points.count - 1, lowSeg + window)
            while j < end {
                let s0 = b.points[j], s1 = b.points[j + 1]
                // B's own distance along its path must be close to A's distance along its path
                if s1.distM >= p.distM - tol, s0.distM <= p.distM + tol {
                    let (d, f) = frame.distanceToSegment(s0, s1)
                    if best == nil || d < best!.d { best = (d, j, f) }
                }
                j += 1
            }
            if let m = best, m.d <= maxOffsetM {
                let s0 = b.points[m.j], s1 = b.points[m.j + 1]
                out.append(CompareMatch(timeA: p.t, timeB: s0.t + (s1.t - s0.t) * m.f, offsetM: m.d))
                lowSeg = m.j
            } else {
                out.append(nil)
            }
        }
        return out
    }

    /// The time difference (B minus A, seconds) at ride A's time `t`: the matches around it, blended; nil in a stretch with no match.
    public static func delta(atTimeA t: Double, matches: [CompareMatch?], path a: ComparePath) -> Double? {
        guard matches.count == a.points.count, !matches.isEmpty else { return nil }
        // the newest matched point at or before t, and the next matched one after
        var before: (i: Int, m: CompareMatch)?
        var after: (i: Int, m: CompareMatch)?
        for (i, p) in a.points.enumerated() {
            guard let m = matches[i] else { continue }
            if p.t <= t { before = (i, m) } else { after = (i, m); break }
        }
        switch (before, after) {
        case let (b?, n?):
            // points between them have no match: a long stretch on different roads says nothing
            if n.i - b.i > 1, a.points[n.i].t - a.points[b.i].t > 15 { return nil }
            let span = a.points[n.i].t - a.points[b.i].t
            let f = span > 0 ? (t - a.points[b.i].t) / span : 0
            return b.m.deltaS + (n.m.deltaS - b.m.deltaS) * f
        case let (b?, nil):
            return t - a.points[b.i].t <= 15 ? b.m.deltaS : nil
        case let (nil, n?):
            return a.points[n.i].t - t <= 15 ? n.m.deltaS : nil
        default:
            return nil
        }
    }

    // MARK: text

    /// "+0:42" / "\u{2212}0:07" / "0:00" (m:ss; hours when needed)
    public static func clock(_ seconds: Double) -> String {
        let t = Int(abs(seconds).rounded())
        let body = t >= 3_600 ? String(format: "%d:%02d:%02d", t / 3_600, t % 3_600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
        if t == 0 { return body }
        return (seconds > 0 ? "+" : "\u{2212}") + body
    }

    /// The neutral sentence under the time difference: "B is 0:42 later at this point" (no winner, no ranking)
    public static func differenceText(_ deltaS: Double?) -> String {
        guard let d = deltaS else { return "The rides took different roads here" }
        let t = Int(abs(d).rounded())
        if t == 0 { return "A and B are together at this point" }
        return "B is \(clock(abs(d)).dropFirst()) \(d > 0 ? "later" : "earlier") at this point"
    }

    /// "0:42" (no sign), for the read-out
    public static func timeFromStart(_ seconds: Double) -> String { String(clock(abs(seconds)).drop(while: { $0 == "+" || $0 == "\u{2212}" })) }
}

/// The synced playback clock: one clock for both rides, same start, 1...50 times faster.
public struct ComparePlayback: Equatable, Sendable {
    public static let speeds: [Double] = [1, 2, 5, 10, 20, 50]
    public static let minSpeed = 1.0
    public static let maxSpeed = 50.0

    public private(set) var time = 0.0
    public private(set) var speed = 10.0
    public private(set) var playing = false
    public let durationS: Double

    public init(durationS: Double) {
        self.durationS = max(0, durationS)
    }

    public mutating func setSpeed(_ s: Double) { speed = min(Self.maxSpeed, max(Self.minSpeed, s)) }

    public mutating func play() {
        if time >= durationS { time = 0 }
        playing = durationS > 0
    }

    public mutating func pause() { playing = false }

    public mutating func scrub(to t: Double) { time = min(durationS, max(0, t)) }

    /// Advance by `dt` real seconds; stops at the end of the longer ride
    public mutating func advance(by dt: Double) {
        guard playing, dt > 0 else { return }
        time += dt * speed
        if time >= durationS {
            time = durationS
            playing = false
        }
    }
}
