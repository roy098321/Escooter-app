import XCTest
@testable import CorckieCore

/// Hotfix 04 (B71): stored ride rows are 5.1–5.3 s apart; the history, the live battery and the voice replay must count every step.
/// Made-up rides on a made-up route only (V09Lab), shaped like a 35 min ride 85 → 48 % with ~340 Wh.
final class Hotfix04Tests: XCTestCase {
    private let wh = V09Lab.storedWhPerPct

    /// The made-up route with `history`, today's estimate = the past rides' usual time (so nobody runs late)
    private func follower(_ history: RouteHistory?) throws -> RouteFollower {
        let h = try XCTUnwrap(history)
        return try XCTUnwrap(V09Lab.follower(todayS: h.usualTotalS ?? 2_060, history: h))
    }

    func testOneGapLimitAboveTheStoredSpacing() {
        XCTAssertEqual(SagProofBattery.maxStepS, RideMetrics.defaultMaxStepS)
        XCTAssertGreaterThan(SagProofBattery.maxStepS, RideRecorderCore.sampleIntervalS + 0.5)
        let ride = V09Lab.storedRide()
        let gaps = zip(ride, ride.dropFirst()).map { $0.1.t - $0.0.t }
        XCTAssertEqual(gaps.min() ?? 0, 5.1, accuracy: 0.001)
        XCTAssertEqual(gaps.max() ?? 0, 5.3, accuracy: 0.001)
        let minutes = ((ride.last?.t ?? 0) - (ride.first?.t ?? 0)) / 60
        XCTAssertEqual(minutes, 35, accuracy: 2)
        XCTAssertEqual(ride.first?.batteryPct, 85)
        XCTAssertEqual(ride.last?.batteryPct, 48)
    }

    func testHistoryProfileCountsFiveSecondRows() throws {
        let f = try XCTUnwrap(V09Lab.follower())
        let checked = RouteRideProfile.makeChecked(samples: V09Lab.storedRide(), route: f, whPerPct: wh)
        XCTAssertNil(checked.leftOut)
        let p = try XCTUnwrap(checked.profile)
        let used = try XCTUnwrap(p.usedPct.last)
        XCTAssertGreaterThan(used, 0)
        XCTAssertEqual(used, 37, accuracy: 3, "close to the battery drop 85 → 48")
        XCTAssertEqual(p.usedPct(atKm: 5) ?? 0, 18.5, accuracy: 2)
    }

    func testTheOldFiveSecondLimitIsLeftOutWithAReason() throws {
        // the B71 shape: every 5.1–5.3 s step dropped = 0 % used while the battery fell 37 % → the sanity guard leaves it out
        let f = try XCTUnwrap(V09Lab.follower())
        let old = RouteRideProfile.makeChecked(samples: V09Lab.storedRide(), route: f, whPerPct: wh, maxStepS: 5)
        XCTAssertNil(old.profile)
        XCTAssertTrue(old.leftOut?.contains("battery fell 37") == true, old.leftOut ?? "no reason")
        // power readings of 0 W all ride long: the same guard
        let dead = V09Lab.storedRide().map { s -> RouteHistorySample in var c = s; c.powerW = 0; return c }
        XCTAssertNil(RouteRideProfile.make(samples: dead, route: f, whPerPct: wh))
        // without power readings the % path still works
        let noPower = V09Lab.storedRide().map { s -> RouteHistorySample in var c = s; c.powerW = nil; c.currentA = nil; return c }
        let pct = try XCTUnwrap(RouteRideProfile.make(samples: noPower, route: f, whPerPct: wh))
        XCTAssertEqual(pct.usedPct.last ?? 0, 37, accuracy: 3)
    }

    func testLiveBatteryCountsFiveSecondSteps() {
        var b = SagProofBattery()
        for s in V09Lab.storedRide() {
            b.update(t: s.t, livePct: s.batteryPct, powerW: s.powerW, currentA: s.currentA, speedKmh: s.speedKmh, whPerPct: wh)
        }
        XCTAssertEqual(b.usedWh, 340, accuracy: 10)
        XCTAssertEqual(b.level ?? 0, 48, accuracy: 1.5)
    }

    func testArrivalIsBelowTheBatteryNowMidRoute() throws {
        let f = try follower(V09Lab.storedHistory())
        let r = V09Replay.run(samples: V09Lab.storedRide(), route: f, whPerPct: wh)
        XCTAssertTrue(r.passed, r.problems.joined(separator: ", "))
        let mid = try XCTUnwrap(r.midRoute)
        let level = try XCTUnwrap(mid.levelPct)
        let arrive = try XCTUnwrap(mid.arrivalPct)
        XCTAssertLessThan(arrive, level - 10, "halfway: arrival \(arrive) vs battery now \(level)")
        XCTAssertEqual(arrive, 48, accuracy: 3)
        XCTAssertEqual(r.realArrivalPct ?? 0, 48, accuracy: 1)
        XCTAssertEqual(r.said.filter { ["drop", "low", "back"].contains($0.kind) }, [], "a usual ride: no battery line")
    }

    func testAHeavyStretchSaysLowerNumbersThanTheBatteryNow() throws {
        let f = try follower(V09Lab.storedHistory())
        let r = V09Replay.run(samples: V09Lab.storedRide(extra: { $0 >= 2 && $0 < 5 ? 2 : 1 }), route: f, whPerPct: wh)
        XCTAssertTrue(r.passed, r.problems.joined(separator: ", ") + " | " + r.said.map(\.line).joined(separator: " | "))
        let lines = r.said.filter { ["drop", "low"].contains($0.kind) }
        XCTAssertFalse(lines.isEmpty, r.said.map(\.line).joined(separator: " | "))
        for l in lines {
            let level = try XCTUnwrap(l.numbers.levelPct)
            XCTAssertLessThan(Double(l.value ?? 100), level - 4, l.line)
        }
    }

    func testReplayFailsTheOldBehaviour() throws {
        // the history B71 built: every past ride used 0 % → arrival = battery now
        let good = try XCTUnwrap(V09Lab.storedHistory()?.rides.first)
        let broken = RouteRideProfile(alongKm: good.alongKm, elapsedS: good.elapsedS, usedPct: good.usedPct.map { _ in 0 })
        let f = try follower(RouteHistory(rides: [broken, broken, broken], routeKm: V09Lab.km))
        let r = V09Replay.run(samples: V09Lab.storedRide(), route: f, whPerPct: wh)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.problems.contains { $0.hasPrefix("halfway the arrival estimate") }, r.problems.joined(separator: ", "))
        XCTAssertEqual(r.said.filter { ["drop", "low", "back"].contains($0.kind) }, [], "under 5 points left to use: no arrival line")
    }

    func testVerdictCatchesTheBatteryNowAndTheSameNumberTwice() {
        func line(_ m: V09Message, level: Double? = nil) -> V09SaidLine {
            var n = V09Numbers()
            n.alongKm = 5
            n.levelPct = level
            return V09SaidLine(m, numbers: n)
        }
        let now = V09Replay.verdict(V09Replay.Result(said: [line(.sharpDrop(pct: 60), level: 61)], realArrivalPct: 58, realArrivalS: nil,
                                                     problems: []), routeKm: 10)
        XCTAssertTrue(now.problems.contains { $0.hasPrefix("said arrival about 60%") }, now.problems.joined(separator: ", "))
        let twice = V09Replay.verdict(V09Replay.Result(said: [line(.everyTen(pct: 60)), line(.sharpDrop(pct: 60), level: 68)],
                                                       realArrivalPct: 58, realArrivalS: nil, problems: []), routeKm: 10)
        XCTAssertTrue(twice.problems.contains("said 60% twice in a row"), twice.problems.joined(separator: ", "))
        let fine = V09Replay.verdict(V09Replay.Result(said: [line(.everyTen(pct: 60)), line(.sharpDrop(pct: 50), level: 59)],
                                                      realArrivalPct: 48, realArrivalS: nil, problems: []), routeKm: 10)
        XCTAssertTrue(fine.passed, fine.problems.joined(separator: ", "))
    }
}
