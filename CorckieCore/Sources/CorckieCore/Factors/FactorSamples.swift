import Foundation

/// M4-02: made-up ride sets whose true factor effects are known (shared by the Core tests and the in-app check u31).
/// No real places or rides.
public enum FactorSamples {
    public static let day = OutsideTime.dayMs
    /// 2026-06-01 00:00 UTC
    public static let t0: Int64 = 1_780_272_000_000

    /// Deterministic noise in [-a, a]
    public struct Noise {
        var x: UInt64
        public init(seed: UInt64) { x = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
        public mutating func next(_ a: Double) -> Double {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(x >> 11) / 9_007_199_254_740_992 * 2 - 1) * a
        }
    }

    /// The truth of `commute`: per trip on a 5 km route
    public static let headSPerKmh = 7.5           // 12 km/h headwind = +90 s, tailwind 12 = -90 s
    public static let rushS = 120.0
    public static let headPctPerKmh = 0.1         // 12 km/h = +1.2 points
    public static let rushPct = 1.0

    /// A 5 km route ridden `n` times on workdays: headwind cycles head 12 / calm 0 / tail -12 km/h, rush hour every other
    /// block of three (independent of the wind); time = 900 s + 7.5 s per km/h + 120 s rush, used = 10% + 0.1 per km/h + 1
    /// rush, plus noise. `effects: false` = the same rides with no effect at all (only noise).
    public static func commute(routeId: String = "A", n: Int = 24, noiseS: Double = 3, noisePct: Double = 0.03, seed: UInt64 = 7,
                               effects: Bool = true, idPrefix: String = "c") -> [FactorRide] {
        var noise = Noise(seed: seed)
        var out: [FactorRide] = []
        for i in 0..<n {
            let hw: Double = [12, 0, -12][i % 3]
            let rush = (i / 3) % 2 == 0
            let k = effects ? 1.0 : 0.0
            let time = 900 + k * (headSPerKmh * hw + (rush ? rushS : 0)) + noise.next(noiseS)
            let used = 10 + k * (headPctPerKmh * hw + (rush ? rushPct : 0)) + noise.next(noisePct)
            out.append(FactorRide(id: "\(idPrefix)\(i)", routeId: routeId, startAt: t0 + Int64(i) * day + (rush ? 8 : 12) * OutsideTime.hourMs,
                                  distanceM: 5_000, totalS: time, usedPct: used, headwindKmh: hw, wet: "dry", rushHour: rush, dayType: "workday"))
        }
        return out
    }

    /// "now" for a set of `n` daily rides: the day after the last one
    public static func now(after n: Int) -> Int64 { t0 + Int64(n + 1) * day }
}
