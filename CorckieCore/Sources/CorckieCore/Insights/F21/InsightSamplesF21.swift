import Foundation

/// F-21: the insight types that are gone (owner, 20 Oct): restated weekly stats on cards, the unexplained "Peak °C · +x °C", and the
/// onboarding hints. They are no longer stored; old rows are removed (`InsightQueries.retireOld`).
public extension InsightType {
    static let retiredF21: Set<InsightType> = [.heatPeak, .firstRide, .unlockTime, .unlockBattery, .unlockCalibration, .unlockRange]
}

/// Made-up rides for the F-21 tests, the checks, the previews and the CI shots (synthetic only; no real place or ride).
public enum InsightSamplesF21 {
    /// A small deterministic noise source in −1...1
    public struct Noise {
        var state: UInt64
        public init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        public mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 11) % 2_000_001) / 1_000_000 - 1
        }
    }

    public static let t0: Int64 = 1_790_000_000_000
    public static let whPerPct = 8.0

    /// The made-up battery % per km at speed v: lowest (0.9) at 28 km/h; `bend` 0 = flat (no sweet spot)
    public static func pctPerKm(_ v: Double, bend: Double = 0.0016) -> Double { 0.9 + bend * (v - 28) * (v - 28) }

    /// `rides` rides, each holding 7 speeds (16 ... 40 km/h) for 90 s with a short slow-down between them
    public static func sweetRides(_ rides: Int, bend: Double = 0.0016, noise: Double = 0.03, seed: UInt64 = 7) -> [SweetSpotRide] {
        var rng = Noise(seed: seed)
        var out: [SweetSpotRide] = []
        for r in 0..<rides {
            var samples: [SpeedSample] = []
            var t = 0.0
            let levels: [Double] = [16, 20, 24, 28, 32, 36, 40]
            for i in 0..<levels.count {
                let v = levels[(i + r) % levels.count]
                let y = pctPerKm(v, bend: bend) * (1 + noise * rng.next())
                for _ in 0..<90 {
                    let vv = v + 0.4 * rng.next()
                    samples.append(SpeedSample(tS: t, speedKmh: vv, powerW: y * whPerPct * vv, altM: 20))
                    t += 1
                }
                for _ in 0..<5 {
                    samples.append(SpeedSample(tS: t, speedKmh: 5, powerW: 60, altM: 20))
                    t += 1
                }
            }
            out.append(SweetSpotRide(id: "s\(r)", startAt: t0 + Int64(r) * 86_400_000, distanceKm: 18, strongWind: false, samples: samples))
        }
        return out
    }

    public static func sweetContext() -> SweetSpotContext {
        SweetSpotContext(whPerPct: whPerPct, usualPctPerKm: 2.9, reservePct: 5, destination: "Work", routeKm: 7.4, routeTimeS: 19 * 60, utcOffsetMin: 180)
    }

    /// The usual route: `habit` rides leaving ~8:10 (19 min) and `early` rides leaving ~7:30 (`gainMin` quicker)
    public static func departureRides(habit: Int = 8, early: Int = 6, gainMin: Double = 6, noiseMin: Double = 0.6, seed: UInt64 = 3) -> [DepartureRide] {
        var rng = Noise(seed: seed)
        var out: [DepartureRide] = []
        let day: Int64 = 86_400_000
        let midnight = t0 - (t0 + 180 * 60_000) % day      // local midnight at +3 h
        for i in 0..<(habit + early) {
            let isEarly = i < early
            let minute = Double(isEarly ? 7 * 60 + 30 : 8 * 60 + 10) + 4 * rng.next()
            let total = (19 - (isEarly ? gainMin : 0) + noiseMin * rng.next()) * 60
            let start = midnight + Int64(i) * day + Int64(minute * 60_000)
            out.append(DepartureRide(startAt: start, utcOffsetMin: 180, totalS: total, distanceKm: 7.4))
        }
        return out
    }

    /// `reference` rides at 0.90 %/km, then `recent` rides `increase` higher, on two routes, mixed speeds and wind
    public static func creepRides(reference: Int = 20, recent: Int = 10, increase: Double = 0.09, noise: Double = 0.005, seed: UInt64 = 5) -> [CreepRide] {
        var rng = Noise(seed: seed)
        var out: [CreepRide] = []
        for i in 0..<(reference + recent) {
            let speed = 24 + 3 * rng.next()
            let wind = 8 * rng.next()
            let base = 0.9 + 0.02 * (speed - 24) + 0.01 * wind
            let y = base * (1 + (i >= reference ? increase : 0)) * (1 + noise * rng.next())
            out.append(CreepRide(id: "c\(i)", startAt: t0 + Int64(i) * 86_400_000 * 2, routeId: i % 2 == 0 ? "A" : "B", pctPerKm: y,
                                 speedKmh: speed, headwindKmh: wind, distanceKm: 7.4))
        }
        return out
    }

    /// Rides with headwind −10 ... 30 km/h; battery %/km grows `slope` per km/h
    public static func windHistory(_ n: Int = 16, slope: Double = 0.03, noise: Double = 0.02, seed: UInt64 = 11) -> [WindRide] {
        var rng = Noise(seed: seed)
        return (0..<n).map { i in
            let hw = -10 + 40 * Double(i) / Double(max(1, n - 1))
            return WindRide(startAt: t0 + Int64(i) * 86_400_000, headwindKmh: hw, pctPerKm: 0.9 + slope * hw + noise * rng.next(), distanceKm: 12)
        }
    }

    public static func windToday(headwindKmh: Double = 26) -> WindToday {
        WindToday(routeTitle: "Work \u{2192} Home", fromName: "Work", toName: "Home", headwindKmh: headwindKmh, windKmh: 28, windFromDeg: 315,
                  departureMinute: 17 * 60, routeKm: 12, usualUsedPct: 11, reservePct: 5)
    }

    /// The outcomes of all four engines on the made-up rides (the CI shots, the previews)
    public static func outcomes() -> [InsightOutcome] {
        [SweetSpotInsight.make(rides: sweetRides(9), context: sweetContext()),
         DepartureInsight.make(rides: departureRides(), destination: "Work", utcOffsetMin: 180),
         CreepInsight.make(rides: creepRides(), reservePct: 5, utcOffsetMin: 180),
         WindTodayInsight.make(history: windHistory(), today: windToday(), utcOffsetMin: 180)]
    }
}
