import Foundation

/// Riding asks (owner 26 Oct, follow-up 5; option (b) picked Sun 1 Nov): the speed graph's card lists one small concrete ask the rider can
/// plan in advance, "800 m steady at 35 km/h fills your speed graph.", with a straight and level (≤ 2 %) stretch of his usual routes
/// where it fits ("Try it on the straight part of your Uni route, about 2.1 km in."; WHERE only, never when). "Not here" remembers that
/// stretch and offers another (riding much slower can be unsafe in traffic: the rider decides). A steady stretch at that speed, measured
/// by POWER over the stretch, fills the SPEED GRAPH ONLY (everything else stays whole-ride %/km); then "Got it ✓" and the next ask.
/// Pure, so it is tested on Linux.

/// A steady stretch as a point of the speed graph
public struct StretchPoint: Equatable, Sendable {
    public var speedKmh: Double
    public var pctPerKm: Double
    public var km: Double
    public var atMs: Int64

    public init(speedKmh: Double, pctPerKm: Double, km: Double, atMs: Int64) {
        self.speedKmh = speedKmh
        self.pctPerKm = pctPerKm
        self.km = km
        self.atMs = atMs
    }

    /// A steady stretch (power) → % per km with the calibration's Wh per %
    public static func from(_ s: SteadyStretch, whPerPct: Double, atMs: Int64) -> StretchPoint? {
        guard whPerPct > 0 else { return nil }
        return StretchPoint(speedKmh: s.speedKmh, pctPerKm: s.whPerKm / whPerPct, km: s.km, atMs: atMs)
    }
}

/// A straight, level stretch of a usual route where an ask fits
public struct AskStretch: Equatable, Sendable {
    /// Stable key for "Not here" (route + rounded ends)
    public var key: String
    public var routeName: String
    /// Where it starts along the route, km
    public var fromKm: Double
    /// N4-2 (batch 4): the stretch itself, in riding order (for "Show where", the street names and the voice cue)
    public var path: [GeoPoint]

    public init(key: String, routeName: String, fromKm: Double, path: [GeoPoint] = []) {
        self.key = key
        self.routeName = routeName
        self.fromKm = fromKm
        self.path = path
    }

    public var start: GeoPoint? { path.first }
    public var end: GeoPoint? { path.last }
    /// The middle point of the stretch (its street name)
    public var middle: GeoPoint? { path.isEmpty ? nil : path[path.count / 2] }

    /// "Try it on the straight part of your Uni route, about 2.1 km in." (no street name: offline, or none there)
    public var line: String { String(format: "Try it on the straight part of your %@ route, about %.1f km in.", routeName, fromKm) }

    /// N4-2 A (owner 9 Nov): the stretch named by its street, "Try it on Herzl St, between Ben Yehuda St and Allenby St (your Uni
    /// route, about 3.5 km in)." The ends' streets are said only when they differ from the stretch's own; no street = `line`.
    public func line(street: String?, fromStreet: String?, toStreet: String?) -> String {
        guard let s = street?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return line }
        let ends = [fromStreet, toStreet].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != s }
        let between = ends.count == 2 && ends[0] != ends[1] ? ", between \(ends[0]) and \(ends[1])" : ""
        return "Try it on \(s)\(between) " + String(format: "(your %@ route, about %.1f km in).", routeName, fromKm)
    }
}

/// One route's recorded path with heights, for finding stretches
public struct AskRoutePath: Equatable, Sendable {
    public var routeId: String
    public var name: String
    /// (point, height m or nil) in riding order
    public var points: [(point: GeoPoint, altM: Double?)]

    public init(routeId: String, name: String, points: [(point: GeoPoint, altM: Double?)]) {
        self.routeId = routeId
        self.name = name
        self.points = points
    }

    public static func == (a: AskRoutePath, b: AskRoutePath) -> Bool {
        a.routeId == b.routeId && a.name == b.name && a.points.count == b.points.count
    }
}

public struct RidingAsk: Equatable, Sendable {
    public var speedKmh: Int
    public var metres: Int
    /// nil = no fitting stretch on the usual routes (the ask still stands)
    public var stretch: AskStretch?

    public init(speedKmh: Int, metres: Int, stretch: AskStretch?) {
        self.speedKmh = speedKmh
        self.metres = metres
        self.stretch = stretch
    }

    /// "800 m steady at 35 km/h fills your speed graph."
    public var line: String { "\(metres) m steady at \(speedKmh) km/h fills your speed graph." }

    /// N4-2: "Any 500 m steady at 20 km/h counts."
    public var anyLine: String { "Any \(metres) m steady at \(speedKmh) km/h counts." }
}

/// N4-2 B (owner 9 Nov): an optional voice cue on reaching the ask's stretch (Settings, off by default, P-4): "Straight ahead: hold
/// twenty for five hundred metres." Once per ride, on coming within `nearM` of the stretch's start from its own side (the end is
/// farther than the start), at riding speed.
public struct AskCue: Equatable, Sendable {
    public static let nearM = 60.0
    public static let minKmh = 8.0

    public let speedKmh: Int
    public let metres: Int
    public let start: GeoPoint
    public let end: GeoPoint
    public private(set) var said = false

    public init(speedKmh: Int, metres: Int, start: GeoPoint, end: GeoPoint) {
        self.speedKmh = speedKmh
        self.metres = metres
        self.start = start
        self.end = end
    }

    public init?(_ ask: RidingAsk) {
        guard let s = ask.stretch, let a = s.start, let b = s.end else { return nil }
        self.init(speedKmh: ask.speedKmh, metres: ask.metres, start: a, end: b)
    }

    /// "Straight ahead: hold twenty for five hundred metres."
    public var line: String {
        let w = SpokenNumber.words
        let m = metres >= 1000 && metres % 1000 == 0 ? "\(w(metres / 1000)) kilometre\(metres == 1000 ? "" : "s")"
            : (metres % 100 == 0 ? "\(w(metres / 100)) hundred metres" : "\(w(metres)) metres")
        return "Straight ahead: hold \(w(speedKmh)) for \(m)."
    }

    /// One position a second; true = say the line now
    public mutating func update(position p: GeoPoint, speedKmh: Double?) -> Bool {
        guard !said, (speedKmh ?? 0) >= Self.minKmh else { return false }
        let toStart = Geo.distanceM(p, start)
        guard toStart <= Self.nearM, Geo.distanceM(p, end) > toStart else { return false }
        said = true
        return true
    }
}

public enum RidingAsks {
    /// The steady-stretch rule (60 s) plus a margin of 20 s
    public static let holdS = 80.0
    /// Straight = no point more than this far from the line between the stretch's ends
    public static let straightM = 15.0
    /// Level = the height changes by at most 2 % of the length (the stretch rule's grade)
    public static let levelGrade = 0.02
    /// A stretch at the asked speed counts within this (the steady band)
    public static let speedBandKmh = 2.5
    /// Asked speeds are whole 5 km/h steps
    public static let speedStep = 5.0

    /// "800": the length that holds the speed for 80 s, rounded up to 100 m
    public static func metres(speedKmh: Double) -> Int {
        Int((speedKmh / 3.6 * holdS / 100).rounded(.up)) * 100
    }

    /// The speed to ask for: the middle of the widest uncovered part of the speed graph, on a 5 km/h step (nil = graph filled)
    public static func speed(covered: [(x: Double, covered: Bool)], wanted: ClosedRange<Double>) -> Int? {
        let steps = covered.filter { wanted.contains($0.x) }
        var best: (from: Double, to: Double)?
        var start: Double?
        var last: Double?
        func close() {
            if let a = start, let b = last, best == nil || b - a > best!.to - best!.from { best = (a, b) }
            start = nil
        }
        for s in steps {
            if s.covered { close() } else { if start == nil { start = s.x }; last = s.x }
        }
        close()
        guard let g = best else { return nil }
        let mid = ((g.from + g.to) / 2 / speedStep).rounded() * speedStep
        return Int(min(wanted.upperBound, max(wanted.lowerBound, mid)))
    }

    /// The straight, level stretches of the usual routes, at least `metres` long, in route order, minus the ones the rider said "Not here" to
    public static func stretches(_ routes: [AskRoutePath], metres: Int, notHere: Set<String>) -> [AskStretch] {
        var out: [AskStretch] = []
        for r in routes {
            let pts = r.points
            guard pts.count >= 2 else { continue }
            var along: [Double] = [0]
            for i in 1..<pts.count { along.append(along[i - 1] + Geo.distanceM(pts[i - 1].point, pts[i].point)) }
            var i = 0
            while i < pts.count {
                // the first j that is far enough from i
                guard let j = (i..<pts.count).first(where: { along[$0] - along[i] >= Double(metres) }) else { break }
                if straight(pts.map(\.point), i, j) && level(pts, i, j, length: along[j] - along[i]) {
                    let key = "\(r.routeId)|\(round3(pts[i].point))|\(round3(pts[j].point))"
                    if !notHere.contains(key) {
                        out.append(AskStretch(key: key, routeName: r.name, fromKm: (along[i] / 100).rounded() / 10,
                                              path: pts[i...j].map(\.point)))
                    }
                    // jump past this stretch: the next one does not overlap it
                    i = j
                    continue
                }
                i += 1
            }
        }
        return out
    }

    static func round3(_ p: GeoPoint) -> String { String(format: "%.3f,%.3f", p.lat, p.lon) }

    static func straight(_ p: [GeoPoint], _ i: Int, _ j: Int) -> Bool {
        let a = p[i], b = p[j]
        let o = a
        let k = 111_320.0, c = cos(o.lat * .pi / 180)
        let bx = (b.lon - o.lon) * k * c, by = (b.lat - o.lat) * k
        let len = (bx * bx + by * by).squareRoot()
        guard len > 1 else { return false }
        for m in i...j {
            let x = (p[m].lon - o.lon) * k * c, y = (p[m].lat - o.lat) * k
            if abs(bx * y - by * x) / len > straightM { return false }
        }
        return true
    }

    static func level(_ p: [(point: GeoPoint, altM: Double?)], _ i: Int, _ j: Int, length: Double) -> Bool {
        let alts = p[i...j].compactMap(\.altM)
        guard alts.count >= 2, let lo = alts.min(), let hi = alts.max(), length > 0 else { return false }
        return (hi - lo) / length <= levelGrade
    }

    /// The ask for now: speed from the graph's widest gap, and the first stretch that fits (nil = graph filled)
    public static func ask(covered: [(x: Double, covered: Bool)], wanted: ClosedRange<Double>, routes: [AskRoutePath], notHere: Set<String>) -> RidingAsk? {
        guard let v = speed(covered: covered, wanted: wanted) else { return nil }
        let m = metres(speedKmh: Double(v))
        return RidingAsk(speedKmh: v, metres: m, stretch: stretches(routes, metres: m, notHere: notHere).first)
    }

    /// "Got it ✓": a steady stretch at the asked speed, long enough, recorded after the ask was made
    public static func done(_ ask: RidingAsk, since ms: Int64, stretches: [StretchPoint]) -> Bool {
        stretches.contains { $0.atMs >= ms && abs($0.speedKmh - Double(ask.speedKmh)) <= speedBandKmh && $0.km * 1000 >= Double(ask.metres) * 0.8 }
    }

    public static let gotIt = "Got it \u{2713}"
}
