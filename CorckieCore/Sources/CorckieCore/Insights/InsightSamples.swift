import Foundation

/// M4-03: made-up inputs that make every catalogue row speak (shared by the Core tests and the in-app check u32).
/// No real places or rides.
public enum InsightSamples {
    public static let now: Int64 = FactorSamples.t0 + 30 * FactorSamples.day

    /// A passed route / pooled effect
    public static func effect(_ factorId: String, _ level: String, _ q: FactorQuantity, _ value: Double?, n: Int = 6, nWithout: Int = 6,
                              scope: FactorScope = .route, routeId: String? = "A") -> FactorEffect {
        FactorEffect(factorId: factorId, level: level, scope: scope, routeId: scope == .route ? routeId : nil, quantity: q, effect: value,
                     n: n, nWithout: nWithout, confidence: value == nil ? FactorGate.notEnoughRides.code : 0.8,
                     gate: value == nil ? .notEnoughRides : .passed)
    }

    public static func variant(_ id: String, _ name: String, timeS: Double, usedPct: Double? = nil, n: Int, gainM: Double = 10,
                               distanceM: Double = 5_000) -> InsightVariant {
        let times = (0..<n).map { timeS + Double($0 % 3 - 1) * 20 }
        let used = usedPct.map { u in (0..<n).map { u + Double($0 % 3 - 1) * 0.2 } } ?? []
        return InsightVariant(id: id, name: name, timesS: times, usedPct: used, gainM: Array(repeating: gainM, count: n),
                              distanceM: Array(repeating: distanceM, count: n))
    }

    /// One example of every catalogue row (and of each progress line), for the wording guard.
    public static func all() -> [Insight] {
        var out: [Insight] = []
        let a = variant("v1", "Ibn Gabirol", timeS: 960, usedPct: 9, n: 8)
        let b = variant("v2", "park shortcut", timeS: 840, usedPct: 12, n: 6, gainM: 2, distanceM: 5_800)
        let guess = DestinationGuess(routeId: "A", share: 0.8, n: 5)
        out += InsightCatalogue.q1Live(guess: guess, destination: "Work", variants: [a, b], todayS: 840, rideId: "r1", nowMs: now)
        out += InsightCatalogue.q1Live(guess: guess, destination: "Work", variants: [a], todayS: 840, rideId: "r1", nowMs: now)
        out += InsightCatalogue.q1q2After(rideId: "r1", routeId: "A", rideVariantId: "v1", rideTimeS: 970, variants: [a, b], nowMs: now)
        out += InsightCatalogue.q1q2After(rideId: "r2", routeId: "A", rideVariantId: "v2", rideTimeS: 830, variants: [a, b], nowMs: now)
        out += InsightCatalogue.q1q2After(rideId: "r3", routeId: "A", rideVariantId: "v1", rideTimeS: 970,
                                          variants: [a, variant("v2", "park shortcut", timeS: 840, n: 2)], nowMs: now)
        out += InsightCatalogue.q2Live(batteryPct: 18, plannedVariantId: "v2", variants: [a, b], routeId: "A", rideId: "r1", nowMs: now)
        out += InsightCatalogue.q3(rideId: "r1", routeId: "A", optionId: "o1", optionName: "park shortcut", rideOptionTimeS: 100,
                                   optionTimesS: [110, 100, 95], otherTimesS: [200, 190, 210], nowMs: now)
        out += InsightCatalogue.q3(rideId: "r1", routeId: "A", optionId: "o2", optionName: "side street", rideOptionTimeS: 100,
                                   optionTimesS: [100, 105, 98], otherTimesS: [110, 100, 104], nowMs: now)
        out += InsightCatalogue.q3(rideId: "r1", routeId: "A", optionId: "o3", optionName: "bridge", rideOptionTimeS: 100,
                                   optionTimesS: [100], otherTimesS: [110, 100, 104], nowMs: now)
        let usualT = UsualRangeValue(lo: 780, hi: 900, median: 840, n: 8, full: false)
        let usualU = UsualRangeValue(lo: 9, hi: 11, median: 10, n: 8, full: false)
        let ex = RideExplanation(items: [.init(factorId: "W1", level: "head", timeS: 70, usedPct: 2, confidence: 0.8),
                                         .init(factorId: "T1", level: "rush", timeS: 50, usedPct: nil, confidence: 0.8)],
                                 actualTimeS: 120, actualUsedPct: 2, otherTimeS: 0, otherPct: 0)
        out += InsightCatalogue.q4After(rideId: "r1", routeId: "A", rideTimeS: 960, rideUsedPct: 13, usualTime: usualT, usualUsed: usualU,
                                        explanation: ex, nowMs: now)
        out += InsightCatalogue.q4After(rideId: "r2", routeId: "A", rideTimeS: 700, rideUsedPct: 10, usualTime: usualT, usualUsed: usualU,
                                        explanation: nil, nowMs: now)
        out += InsightCatalogue.q4Weekly(weekStart: now, explanations: [ex, ex, ex], nowMs: now)
        let tab = ThereAndBackModel(status: .oneWayOnly, symbol: "\u{274C}", headline: "", detail: "", sparePct: nil, destination: "Work", batteryPct: 20)
        out += InsightCatalogue.q9Live(model: tab, routeId: "A", rideId: "r1", basedOnN: 6, nowMs: now)
        let caps = (0..<5).map { _ in CapRide(timeAtMaxPct: 70, totalS: 800, usedPct: 13) } + (0..<5).map { _ in CapRide(timeAtMaxPct: 10, totalS: 900, usedPct: 10) }
        out += InsightCatalogue.q13After(rideId: "r1", routeId: "A", routeName: "Home to Work", rides: caps, nowMs: now)
        out += InsightCatalogue.q13After(rideId: "r1", routeId: "A", routeName: "Home to Work", rides: Array(caps.prefix(4)), nowMs: now)
        let week = (0..<4).map { WeekRide(startAt: now + Int64($0) * FactorSamples.day, utcOffsetMin: 180, kind: "ride", distanceM: 5_000,
                                          totalS: 900, movingS: 850, usedPct: 10, timeAtMaxPct: 38) }
        out += InsightCatalogue.q13Weekly(weekStart: now, rides: week, capKmh: 25, savedS: 240, costPct: 6, nowMs: now)
        let route = [effect("W1", "head", .time, 90), effect("W1", "head", .used, 1.2), effect("W1", "tail", .time, -80), effect("W1", "tail", .used, -1.1)]
        out += InsightCatalogue.q15Live(routeId: "A", routeName: "Home to Work", forecastHeadwindKmh: 20, routeEffects: route, rideId: "r1", nowMs: now)
        out += InsightCatalogue.q15Live(routeId: "A", routeName: "Home to Work", forecastHeadwindKmh: -20, routeEffects: route, rideId: "r1", nowMs: now)
        let tail = RideExplanation(items: [.init(factorId: "W1", level: "tail", timeS: -70, usedPct: -2, confidence: 0.8)])
        out += InsightCatalogue.q15After(rideId: "r1", routeId: "A", routeName: "Home to Work", rideHeadwindKmh: -12, explanation: tail,
                                         routeEffects: route, nowMs: now)
        out += InsightCatalogue.q15After(rideId: "r1", routeId: "A", routeName: "Home to Work", rideHeadwindKmh: 12, explanation: ex,
                                         routeEffects: route, nowMs: now)
        out += InsightCatalogue.q15After(rideId: "r2", routeId: "A", routeName: "Home to Work", rideHeadwindKmh: 12, explanation: nil,
                                         routeEffects: [effect("W1", "head", .time, nil, n: 2, nWithout: 4)], nowMs: now)
        let pooled = [effect("W1", "head", .time, 10, scope: .pooled), effect("W1", "head", .used, 0.15, scope: .pooled),
                      effect("L1", "perKg", .time, 0.4, n: 4, scope: .pooled), effect("L1", "perKg", .used, 0.03, n: 4, scope: .pooled)]
        out += InsightCatalogue.q15Notify(routeId: "A", routeName: "Home to Work", routeKm: 5, likelyRideSoon: true, forecastHeadwindKmh: 20,
                                          previousForecastKmh: 5, pooledEffects: pooled, rangeKm: 30, usualPctPerKm: 2, nowMs: now)
        out += InsightCatalogue.q17New(rideId: "r1", routeId: "A", climbId: "c1", climbName: "Bridge ramp", gainM: 18, nowMs: now)
        out += InsightCatalogue.q18(rideId: "r1", routeId: "A", variants: [a, b], nowMs: now)
        out += InsightCatalogue.q19After(rideId: "r1", routeId: "A", loadKg: 15, loadLevel: "heavy", rideKm: 5, pooledEffects: pooled, nowMs: now)
        out += InsightCatalogue.q19After(rideId: "r2", routeId: "A", loadKg: 5, loadLevel: "light", rideKm: 5,
                                         pooledEffects: [effect("L1", "perKg", .used, nil, n: 2, nWithout: 30, scope: .pooled)], nowMs: now)
        let hop = WeekRide(startAt: now + 2 * FactorSamples.day, utcOffsetMin: 180, kind: "shortHop", distanceM: 1_400, totalS: 300, usedPct: 2)
        out += InsightCatalogue.q22Weekly(weekStart: now, rides: week + [hop], previousWeekKm: 18, nowMs: now)
        out += InsightCatalogue.firstAndUnlock(rideId: "r1", realRides: 1, routeId: "A", routeName: "Home to Work", routeRides: 3, routeBatteryRides: 5,
                                               calibratedNow: true, whPerPct: 8.4, firstRangeKm: 31, nowMs: now)
        let usual = (0..<6).map { HeatRide(riseC: 30 + Double($0), distanceKm: 6, airTempC: 22) }
        out += InsightCatalogue.heatAfter(rideId: "r1", routeId: "A", peakC: 92, ride: HeatRide(riseC: 68, distanceKm: 6, airTempC: 33), routeRides: usual, nowMs: now)
        out += InsightCatalogue.heatAfter(rideId: "r2", routeId: "A", peakC: nil, ride: HeatRide(riseC: 48, distanceKm: 6, airTempC: 22), routeRides: usual, nowMs: now)
        return out
    }
}
