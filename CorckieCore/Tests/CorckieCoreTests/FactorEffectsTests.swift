import XCTest
@testable import CorckieCore

/// M4-02: the factor effects (M24) on made-up ride sets whose true effects are known: recovered within 10%,
/// stratification beats a confounded rush hour, the regression confirmation, the gates (M15: counts, MAD, rare factors
/// pooled), combined factors, load per kg (M23), pure noise shows nothing, weather missing, the after-ride explanation.
final class FactorEffectsTests: XCTestCase {
    private let day = FactorSamples.day
    private let t0 = FactorSamples.t0

    private func find(_ e: [FactorEffect], _ id: String, _ level: String, _ scope: FactorScope, _ q: FactorQuantity,
                      route: String? = nil) throws -> FactorEffect {
        try XCTUnwrap(e.first { $0.factorId == id && $0.level == level && $0.scope == scope && $0.quantity == q && $0.routeId == route },
                      "\(id) \(level) \(scope) \(q) \(route ?? "-")")
    }

    private func ride(_ id: String, route: String = "R", i: Int, time: Double, used: Double? = nil, hw: Double? = 0, wet: String? = "dry",
                      rush: Bool = false, load: Double? = nil) -> FactorRide {
        FactorRide(id: id, routeId: route, startAt: t0 + Int64(i) * day + 12 * OutsideTime.hourMs, distanceM: 5_000, totalS: time, usedPct: used,
                   headwindKmh: hw, wet: wet, rushHour: rush, dayType: "workday", loadKg: load)
    }

    // MARK: Known effects are recovered

    func test_commute_recoversWindAndRushHour_within10Percent() throws {
        let e = FactorEngine.compute(rides: FactorSamples.commute(), nowMs: FactorSamples.now(after: 24))
        let head = try find(e, "W1", "head", .route, .time, route: "A")
        XCTAssertTrue(head.passesGate, "\(head)")
        XCTAssertEqual(try XCTUnwrap(head.timeEffectS), 90, accuracy: 9)
        XCTAssertEqual(head.n, 8)
        XCTAssertEqual(head.nWithout, 8)
        XCTAssertEqual(head.basedOnN, 16)
        XCTAssertGreaterThan(head.confidence, 0)
        let tail = try find(e, "W1", "tail", .route, .time, route: "A")
        XCTAssertEqual(try XCTUnwrap(tail.timeEffectS), -90, accuracy: 9)
        let rush = try find(e, "T1", "rush", .route, .time, route: "A")
        XCTAssertEqual(try XCTUnwrap(rush.timeEffectS), 120, accuracy: 12)
        XCTAssertEqual(rush.n, 12)
        let headPct = try find(e, "W1", "head", .route, .used, route: "A")
        XCTAssertEqual(try XCTUnwrap(headPct.usedEffectPct), 1.2, accuracy: 0.12)
        XCTAssertNil(headPct.timeEffectS)
        let rushPct = try find(e, "T1", "rush", .route, .used, route: "A")
        XCTAssertEqual(try XCTUnwrap(rushPct.usedEffectPct), 1.0, accuracy: 0.1)
        // pooled per km (5 km): 90 s per trip = 18 s/km
        let pooled = try find(e, "W1", "head", .pooled, .time)
        XCTAssertEqual(try XCTUnwrap(pooled.effect), 18, accuracy: 1.8)
        // nothing else is claimed: no rain, hills, load or day type in these rides
        for id in ["W3", "R1", "L1", "T2"] {
            XCTAssertTrue(e.filter { $0.factorId == id }.allSatisfy { !$0.passesGate && $0.effect == nil }, id)
        }
    }

    func test_stratification_beatsAConfoundedRushHour() throws {
        // rush-hour rides are mostly windy (7 of 10), the others mostly calm (4 of 20); true rush hour = +30 s, headwind = +90 s
        var noise = FactorSamples.Noise(seed: 3)
        var rides: [FactorRide] = []
        for i in 0..<30 {
            let rush = i < 10
            let head = rush ? i < 7 : i < 14
            rides.append(ride("b\(i)", route: "B", i: i, time: 900 + (head ? 90 : 0) + (rush ? 30 : 0) + noise.next(1), hw: head ? 12 : 0, rush: rush))
        }
        let naive = try XCTUnwrap(Geo.median(rides.filter(\.rushHour).compactMap(\.totalS))) - XCTUnwrap(Geo.median(rides.filter { !$0.rushHour }.compactMap(\.totalS)))
        XCTAssertGreaterThan(naive, 90, "a plain with / without comparison mistakes the wind for rush hour")
        let e = FactorEngine.compute(rides: rides, nowMs: FactorSamples.now(after: 30))
        let rush = try find(e, "T1", "rush", .route, .time, route: "B")
        XCTAssertEqual(try XCTUnwrap(rush.timeEffectS), 30, accuracy: 6)
        XCTAssertEqual(try XCTUnwrap(try find(e, "W1", "head", .route, .time, route: "B").timeEffectS), 90, accuracy: 9)
    }

    func test_pureNoise_showsNothing() {
        let rides = FactorSamples.commute(n: 120, noiseS: 30, noisePct: 0.5, effects: false)
        let e = FactorEngine.compute(rides: rides, nowMs: FactorSamples.now(after: 120))
        XCTAssertFalse(e.isEmpty)
        XCTAssertEqual(e.filter(\.passesGate).map { "\($0.factorId) \($0.level) \($0.scope) \($0.quantity)" }, [])
    }

    // MARK: Confirmation (T76)

    func test_confirmation_signAndTimesTwo() {
        XCTAssertTrue(FactorEngine.confirms(main: 10, regression: 6))
        XCTAssertTrue(FactorEngine.confirms(main: 10, regression: 20))
        XCTAssertTrue(FactorEngine.confirms(main: -10, regression: -19))
        XCTAssertFalse(FactorEngine.confirms(main: 10, regression: -5), "sign disagrees")
        XCTAssertFalse(FactorEngine.confirms(main: 10, regression: 4), "more than x2 apart")
        XCTAssertFalse(FactorEngine.confirms(main: -10, regression: -21))
        XCTAssertFalse(FactorEngine.confirms(main: 10, regression: nil), "the regression cannot tell")
    }

    func test_ridgeDisagreement_hidesTheEffect() throws {
        let rides = FactorSamples.commute()
        let def = try XCTUnwrap(FactorEngine.defs.first { $0.id == "W1" && $0.level == "head" })
        // the same comparison, once with a regression that agrees (18 s/km) and once with one of the other sign
        let agree = FactorEngine.evaluate(def: def, member: def.member, rides: rides, value: { $0.totalS }, q: .time, strataGroups: ["T1"],
                                          regression: 18, perKmScale: 0.2, perKg: false)
        XCTAssertEqual(agree.gate, .passed)
        XCTAssertEqual(try XCTUnwrap(agree.effect), 90, accuracy: 9)
        let disagree = FactorEngine.evaluate(def: def, member: def.member, rides: rides, value: { $0.totalS }, q: .time, strataGroups: ["T1"],
                                             regression: -18, perKmScale: 0.2, perKg: false)
        XCTAssertEqual(disagree.gate, .notConfirmed)
        XCTAssertNil(disagree.effect)
        XCTAssertEqual(disagree.n, 8)
    }

    // MARK: Gates (M15)

    func test_gate_counts_timeNeeds3_batteryNeeds5() throws {
        var noise = FactorSamples.Noise(seed: 11)
        var rides: [FactorRide] = []
        for i in 0..<12 {
            let head = i % 3 == 0          // 4 windy rides, 8 calm
            rides.append(ride("g\(i)", route: "G", i: i, time: 900 + (head ? 90 : 0) + noise.next(3), used: 10 + (head ? 1.2 : 0) + noise.next(0.03),
                              hw: head ? 12 : 0))
        }
        let e = FactorEngine.compute(rides: rides, nowMs: FactorSamples.now(after: 12))
        let time = try find(e, "W1", "head", .route, .time, route: "G")
        XCTAssertTrue(time.passesGate)
        XCTAssertEqual(try XCTUnwrap(time.timeEffectS), 90, accuracy: 9)
        let used = try find(e, "W1", "head", .route, .used, route: "G")
        XCTAssertEqual(used.gate, .notEnoughRides)
        XCTAssertNil(used.effect)
        XCTAssertNil(used.usedEffectPct)
        XCTAssertEqual(used.n, 4)
        XCTAssertEqual(used.nWithout, 8)
        XCTAssertEqual(used.needed, 5)
        // 2 windy rides: "2 of 3" (pattern D), no value
        let two = FactorEngine.compute(rides: Array(rides.filter { $0.headwindKmh == 0 }) + rides.filter { $0.headwindKmh == 12 }.prefix(2),
                                       nowMs: FactorSamples.now(after: 12))
        let t2 = try find(two, "W1", "head", .route, .time, route: "G")
        XCTAssertEqual(t2.gate, .notEnoughRides)
        XCTAssertEqual(t2.n, 2)
        XCTAssertEqual(t2.needed, 3)
        XCTAssertNil(t2.effect)
    }

    func test_gate_effectInsideTheNoise_isNotShown() throws {
        var noise = FactorSamples.Noise(seed: 5)
        let rides = (0..<120).map { i -> FactorRide in
            let head = i % 2 == 0
            return ride("m\(i)", route: "M", i: i, time: 900 + (head ? 10 : 0) + noise.next(80), hw: head ? 12 : 0)
        }
        let e = FactorEngine.compute(rides: rides, nowMs: FactorSamples.now(after: 120))
        let head = try find(e, "W1", "head", .route, .time, route: "M")
        XCTAssertEqual(head.n, 60)
        XCTAssertFalse(head.passesGate, "10 s inside a +-80 s spread")
        XCTAssertNil(head.effect)
    }

    func test_rain_isPooledPerKm_overRoutes() throws {
        var noise = FactorSamples.Noise(seed: 9)
        var rides: [FactorRide] = []
        for (r, route) in ["P", "Q"].enumerated() {
            for i in 0..<8 {
                let wet = i < 3
                rides.append(ride("\(route)\(i)", route: route, i: r * 8 + i, time: 900 + (wet ? 60 : 0) + noise.next(1), wet: wet ? "light" : "dry"))
            }
        }
        let e = FactorEngine.compute(rides: rides, nowMs: FactorSamples.now(after: 16))
        XCTAssertTrue(e.filter { $0.factorId == "W3" }.allSatisfy { $0.scope == .pooled }, "rain is a rare factor: pooled only")
        let wet = try find(e, "W3", "wet", .pooled, .time)
        XCTAssertEqual(wet.n, 6)
        XCTAssertEqual(wet.nWithout, 10)
        XCTAssertEqual(try XCTUnwrap(wet.timeEffectS), 12, accuracy: 1.2)   // 60 s per 5 km
    }

    func test_combinedFactors_untilApart() throws {
        var noise = FactorSamples.Noise(seed: 13)
        var rides: [FactorRide] = []
        for i in 0..<12 {
            let storm = i < 5
            rides.append(ride("s\(i)", route: "S", i: i, time: 900 + (storm ? 100 : 0) + noise.next(1), hw: storm ? 12 : 0, wet: storm ? "light" : "dry"))
        }
        let e = FactorEngine.compute(rides: rides, nowMs: FactorSamples.now(after: 12))
        XCTAssertEqual(try find(e, "W1", "head", .pooled, .time).gate, .combined)
        XCTAssertEqual(try find(e, "W3", "wet", .pooled, .time).gate, .combined)
        let storm = try find(e, "W1+W3", "head+wet", .pooled, .time)
        XCTAssertTrue(storm.passesGate, "\(storm)")
        XCTAssertEqual(try XCTUnwrap(storm.effect), 20, accuracy: 2)
        XCTAssertEqual(storm.n, 5)
        // the after-ride explanation uses the combined row for a stormy ride
        let ex = FactorEngine.explain(ride: rides[0], routeRides: rides, effects: e.filter { $0.scope == .pooled }, nowMs: FactorSamples.now(after: 12))
        XCTAssertEqual(ex.items.map(\.factorId), ["W1+W3"])
        // 3 rides apart (windy but dry): no longer combined
        var apart = rides
        for i in 0..<3 { apart.append(ride("w\(i)", route: "S", i: 12 + i, time: 950, hw: 12, wet: "dry")) }
        let e2 = FactorEngine.compute(rides: apart, nowMs: FactorSamples.now(after: 15))
        XCTAssertNotEqual(try find(e2, "W1", "head", .pooled, .time).gate, .combined)
    }

    func test_load_perKg_withPlausibility() throws {
        func rides(share: Double) -> [FactorRide] {
            var noise = FactorSamples.Noise(seed: 17)
            var out: [FactorRide] = []
            for (r, route) in ["L", "K"].enumerated() {
                for i in 0..<8 {
                    let loaded = i < 3
                    out.append(ride("\(route)\(i)", route: route, i: r * 8 + i, time: 900, used: 10 * (1 + (loaded ? share : 0)) + noise.next(0.005),
                                    load: loaded ? 15 : nil))
                }
            }
            return out
        }
        let e = FactorEngine.compute(rides: rides(share: 0.05), nowMs: FactorSamples.now(after: 16))
        let perKg = try find(e, "L1", "perKg", .pooled, .used)
        XCTAssertTrue(perKg.passesGate, "\(perKg)")
        XCTAssertEqual(try XCTUnwrap(perKg.effect), 0.1 / 15, accuracy: 0.1 / 15 * 0.1)   // %/km per kg
        XCTAssertFalse(perKg.uncertain)
        XCTAssertEqual(perKg.n, 6)
        XCTAssertFalse(e.contains { $0.factorId == "L1" && $0.scope == .route }, "load is pooled only")
        // time does not change with the load: nothing shown
        XCTAssertFalse(try find(e, "L1", "perKg", .pooled, .time).passesGate)
        // +50% for 15 kg is far beyond the physics (3x kg / (75 + 20) x 0.4): uncertain
        let big = FactorEngine.compute(rides: rides(share: 0.5), nowMs: FactorSamples.now(after: 16))
        let u = try XCTUnwrap(big.first { $0.factorId == "L1" && $0.quantity == .used && $0.scope == .pooled })
        XCTAssertEqual(u.level, "perKgUncertain")
        XCTAssertTrue(u.uncertain)
        XCTAssertLessThanOrEqual(u.confidence, 0.3)
    }

    func test_weatherMissing_noCrash_windLeftOut() throws {
        let rides = FactorSamples.commute().map { r -> FactorRide in
            var x = r
            x.headwindKmh = nil
            x.wet = nil
            return x
        }
        let e = FactorEngine.compute(rides: rides, nowMs: FactorSamples.now(after: 24))
        let head = try find(e, "W1", "head", .route, .time, route: "A")
        XCTAssertEqual(head.n, 0)
        XCTAssertEqual(head.nWithout, 0)
        XCTAssertEqual(head.gate, .notEnoughRides)
        let ex = FactorEngine.explain(ride: rides[0], routeRides: rides, effects: e, nowMs: FactorSamples.now(after: 24))
        XCTAssertTrue(ex.weatherMissing)
        XCTAssertFalse(ex.items.contains { $0.factorId == "W1" })
    }

    func test_excludedShortAndGappyRides_areLeftOut() throws {
        var rides = FactorSamples.commute()
        rides[0].excluded = true
        rides[3].kind = "shortHop"
        rides[6].distanceM = 400
        rides[9].gapScooterS = 120
        let e = FactorEngine.compute(rides: rides, nowMs: FactorSamples.now(after: 24))
        XCTAssertEqual(try find(e, "W1", "head", .route, .time, route: "A").n, 5)
        XCTAssertEqual(try find(e, "W1", "head", .route, .used, route: "A").n, 4, "a gap over 60 s leaves the battery out only")
    }

    // MARK: After-ride explanation

    func test_explanation_scaledToTheRealDifference_restIsOther() throws {
        let now = FactorSamples.now(after: 10)
        let others = (0..<5).map { ride("o\($0)", route: "A", i: $0, time: 900) }
        let effects = [
            FactorEffect(factorId: "W1", level: "head", scope: .route, routeId: "A", quantity: .time, effect: 90, n: 8, nWithout: 8, confidence: 0.8, gate: .passed),
            FactorEffect(factorId: "T1", level: "rush", scope: .route, routeId: "A", quantity: .time, effect: 120, n: 8, nWithout: 8, confidence: 0.7, gate: .passed),
            FactorEffect(factorId: "W3", level: "wet", scope: .pooled, routeId: nil, quantity: .time, effect: 12, n: 6, nWithout: 9, confidence: 0.6, gate: .passed),
            FactorEffect(factorId: "W1", level: "head", scope: .route, routeId: "A", quantity: .used, effect: nil, n: 3, nWithout: 8, confidence: -1, gate: .notEnoughRides)
        ]
        func explain(_ time: Double, wet: String = "dry") -> RideExplanation {
            let r = ride("x", route: "A", i: 8, time: time, hw: 12, wet: wet, rush: true)
            return FactorEngine.explain(ride: r, routeRides: others + [r], effects: effects, nowMs: now)
        }
        // 100 s slower, factors say 210: scaled down, nothing left
        let a = explain(1000)
        XCTAssertEqual(try XCTUnwrap(a.actualTimeS), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(a.items.first { $0.factorId == "W1" }?.timeS), 100 * 90 / 210, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(a.items.first { $0.factorId == "T1" }?.timeS), 100 * 120 / 210, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(a.otherTimeS), 0, accuracy: 1e-9)
        XCTAssertNil(a.items.first { $0.factorId == "W1" }?.usedPct, "a battery effect under its gate is not used")
        XCTAssertNil(a.actualUsedPct)
        // 400 s slower: factors kept, 190 s is other
        let b = explain(1300)
        XCTAssertEqual(try XCTUnwrap(b.items.first { $0.factorId == "W1" }?.timeS), 90, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(b.otherTimeS), 190, accuracy: 1e-9)
        // faster than usual despite the factors: the rest is negative "other"
        let c = explain(850)
        XCTAssertEqual(try XCTUnwrap(c.otherTimeS), -260, accuracy: 1e-9)
        // pooled per km x the ride's km for a factor with no route value (rain: 12 s/km x 5 km)
        let d = explain(1300, wet: "light")
        XCTAssertEqual(try XCTUnwrap(d.items.first { $0.factorId == "W3" }?.timeS), 60, accuracy: 1e-9)
        XCTAssertFalse(d.weatherMissing)
        // a route with fewer than 3 other rides: no "usual", no other
        let r = ride("y", route: "A", i: 8, time: 1000, hw: 12, rush: true)
        let few = FactorEngine.explain(ride: r, routeRides: Array(others.prefix(2)) + [r], effects: effects, nowMs: now)
        XCTAssertNil(few.actualTimeS)
        XCTAssertNil(few.otherTimeS)
        XCTAssertEqual(few.items.count, 2)
    }

    func test_gateCodes_roundTrip() {
        for g in [FactorGate.notEnoughRides, .withinNoise, .notConfirmed, .combined] {
            XCTAssertEqual(FactorGate.from(confidence: g.code), g)
        }
        XCTAssertEqual(FactorGate.from(confidence: 0.4), .passed)
        XCTAssertEqual(FactorGate.from(confidence: nil), .notEnoughRides)
    }

    func test_ridge_recoversALinearModel() throws {
        // y = 2 x1 - 3 x2 (+ a constant), no noise: tiny penalty, close to exact
        var x: [[Double]] = []
        var y: [Double] = []
        for i in 0..<40 {
            let a = Double(i % 7), b = Double((i * 3) % 5)
            x.append([a, b, 1])
            y.append(5 + 2 * a - 3 * b)
        }
        let fit = try XCTUnwrap(FactorEngine.ridge(x: x, y: y, lambda: 0.001))
        XCTAssertEqual(try XCTUnwrap(fit.beta[0]), 2, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(fit.beta[1]), -3, accuracy: 0.01)
        XCTAssertNil(fit.beta[2], "a column without spread is left out")
    }
}
