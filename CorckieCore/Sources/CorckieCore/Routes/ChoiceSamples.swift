import Foundation

/// M6-01: made-up ride sets with known option times for the Q23 tests, the in-app check u42 and the app-tests. A straight 4 km
/// route north in the ocean (no real place) with two choice points: a "park" detour at 0.8-1.4 km (east) and a "left" detour at
/// 2.4-3.0 km (west). Times are per piece at a steady speed, factor effects are spread over the pieces by length (as M24 assumes).
public enum ChoiceSamples {
    public static let routeId = "seed-choice"
    public static let lat0 = 10.0
    public static let lon0 = -30.0
    public static let routeM = 4_000.0
    /// 2026-05-03 05:00 UTC (a Sunday)
    public static let t0: Int64 = 1_777_784_400_000
    public static let day: Int64 = 86_400_000
    public static let sharedMps = 6.0

    /// The usual times (s) of each piece (the usual ways have traffic lights)
    public static let ref1S = 180.0
    public static let parkS = 80.0
    public static let ref2S = 170.0
    public static let leftS = 75.0

    public typealias XY = (x: Double, y: Double)

    public static func geo(_ p: XY) -> GeoPoint {
        let mPerDeg = Double.pi * Geo.earthRadiusM / 180
        return GeoPoint(lat: lat0 + p.y / mPerDeg, lon: lon0 + p.x / (mPerDeg * cos(lat0 * Double.pi / 180)))
    }

    public static let referenceXY: [XY] = [(0, 0), (0, 4_000)]
    public static let parkXY: [XY] = [(0, 800), (150, 900), (150, 1_300), (0, 1_400)]
    /// A third way at the first choice point (west of it), for "option seen once"
    public static let otherXY: [XY] = [(0, 800), (-160, 900), (-160, 1_300), (0, 1_400)]
    public static let leftXY: [XY] = [(0, 2_400), (-120, 2_500), (-120, 2_900), (0, 3_000)]

    public static var reference: [GeoPoint] { referenceXY.map(geo) }

    public enum Way1: Sendable { case usual, park, other }

    public struct Spec: Sendable {
        public var way1: Way1
        public var left: Bool
        public var levels: Set<String>
        public var way1S: Double?
        public var way2S: Double?
        /// Remove the fixes between these metres along the ride (a GPS gap)
        public var gapM: ClosedRange<Double>?

        public init(_ way1: Way1, left: Bool, levels: Set<String> = [], way1S: Double? = nil, way2S: Double? = nil,
                    gapM: ClosedRange<Double>? = nil) {
            self.way1 = way1
            self.left = left
            self.levels = levels
            self.way1S = way1S
            self.way2S = way2S
            self.gapM = gapM
        }
    }

    static func length(_ xy: [XY]) -> Double {
        var total = 0.0
        if xy.count < 2 { return 0 }
        for i in 1..<xy.count { total += hypot(xy[i].x - xy[i - 1].x, xy[i].y - xy[i - 1].y) }
        return total
    }

    /// Small repeatable noise in -1...1
    static func noise(_ seed: Int, _ k: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: seed &* 7_919 &+ k &* 104_729 &+ 1)
        x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((x >> 33) % 2_001) / 1_000 - 1
    }

    /// One ride of the spec: fixes every 2 s (+-3 m noise), battery 1.5% per km, energy 12 Wh per km; `tripEffectsS` by level
    /// spread over the pieces by length.
    public static func ride(id: String, startAt: Int64, spec: Spec, tripEffectsS: [String: Double] = [:], seed: Int)
        -> (choice: ChoiceRide, ride: CombinationRide) {
        let effect = spec.levels.reduce(0.0) { $0 + (tripEffectsS[$1] ?? 0) }
        let way1XY: [XY]
        var way1Base: Double
        switch spec.way1 {
        case .usual: way1XY = [(0, 800), (0, 1_400)]; way1Base = ref1S
        case .park: way1XY = parkXY; way1Base = parkS
        case .other: way1XY = otherXY; way1Base = parkS + 40
        }
        if let s = spec.way1S { way1Base = s }
        let way2XY: [XY] = spec.left ? leftXY : [(0, 2_400), (0, 3_000)]
        var way2Base = spec.left ? leftS : ref2S
        if let s = spec.way2S { way2Base = s }
        let pieces: [([XY], Double)] = [
            ([(0, 0), (0, 800)], 800 / sharedMps),
            (way1XY, way1Base + 3 * noise(seed, 1)),
            ([(0, 1_400), (0, 2_400)], 1_000 / sharedMps),
            (way2XY, way2Base + 3 * noise(seed, 2)),
            ([(0, 3_000), (0, 4_000)], 1_000 / sharedMps)
        ]
        var fixes: [TimedFix] = []
        var t = 0.0
        var walked = 0.0
        var k = 0
        for (xy, baseS) in pieces {
            let len = length(xy)
            let timeS = baseS + effect * len / routeM
            let step = 2.0
            var s = 0.0
            while s < timeS {
                let d = len * s / timeS
                let p = point(on: xy, at: d)
                let along = walked + d
                k += 1
                if spec.gapM?.contains(along) != true {
                    let g = geo((p.x + 3 * noise(seed, 10 + k), p.y + 3 * noise(seed, 20_000 + k)))
                    fixes.append(TimedFix(t: t + s, lat: g.lat, lon: g.lon, hAccM: 5, batteryPct: 80 - 1.5 * along / 1_000,
                                          energyWh: 12 * along / 1_000))
                }
                s += step
            }
            t += timeS
            walked += len
        }
        let end = geo((0, 4_000))
        fixes.append(TimedFix(t: t, lat: end.lat, lon: end.lon, hAccM: 5, batteryPct: 80 - 1.5 * walked / 1_000, energyWh: 12 * walked / 1_000))
        return (ChoiceRide(id: id, startAt: startAt, fixes: fixes),
                CombinationRide(id: id, startAt: startAt, totalS: t, excluded: false, levels: spec.levels))
    }

    static func point(on xy: [XY], at d: Double) -> XY {
        var left = d
        for i in 1..<xy.count {
            let dx = xy[i].x - xy[i - 1].x
            let dy = xy[i].y - xy[i - 1].y
            let len = hypot(dx, dy)
            if left <= len || i == xy.count - 1 {
                let f = len > 0 ? min(1, left / len) : 0
                return (xy[i - 1].x + dx * f, xy[i - 1].y + dy * f)
            }
            left -= len
        }
        return xy[xy.count - 1]
    }

    /// A ride set, one ride a day from `t0` (ids "c1", "c2", ...).
    public static func rides(_ specs: [Spec], tripEffectsS: [String: Double] = [:]) -> (choice: [ChoiceRide], rides: [CombinationRide]) {
        var choice: [ChoiceRide] = []
        var rides: [CombinationRide] = []
        for (i, s) in specs.enumerated() {
            let r = ride(id: "c\(i + 1)", startAt: t0 + Int64(i) * day, spec: s, tripEffectsS: tripEffectsS, seed: i + 1)
            choice.append(r.choice)
            rides.append(r.ride)
        }
        return (choice, rides)
    }

    /// 3 rides the usual way, 3 via the park, 3 left at the lights: the park + left combination was never ridden.
    public static var nineRides: [Spec] {
        Array(repeating: Spec(.usual, left: false), count: 3) + Array(repeating: Spec(.park, left: false), count: 3)
            + Array(repeating: Spec(.usual, left: true), count: 3)
    }

    /// Detection + answer in one go (what the app does after a ride).
    public static func answer(_ specs: [Spec], tripEffectsS: [String: Double] = [:], usedEffectsS: [String: Double]? = nil,
                              todayLevels: Set<String> = []) -> (set: ChoiceSet, answer: FastestAnswer) {
        let made = rides(specs, tripEffectsS: tripEffectsS)
        let set = ChoicePointDetector.detect(routeId: routeId, reference: reference, rides: made.choice, routeLengthM: routeM)
        let input = CombinationInput(routeId: routeId, reference: reference, routeLengthM: routeM, choices: set, rides: made.rides,
                                     tripEffectsS: usedEffectsS ?? tripEffectsS, todayLevels: todayLevels,
                                     nowMs: t0 + Int64(specs.count + 1) * day)
        return (set, FastestCombination.answer(input))
    }
}
