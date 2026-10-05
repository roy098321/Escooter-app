import XCTest
@testable import CorckieCore

/// M3-02: charge log from rested % jumps (M30), cycles (M31), battery health (M32). Made-up numbers only.
final class ChargeLogTests: XCTestCase {
    static let day: Int64 = 86_400_000
    let t0: Int64 = 20_000 * 86_400_000

    private func ride(_ id: String, hours: Double, from: Double?, to: Double?, live: Double? = nil, used: Double? = nil,
                      sim: Bool = false, kind: String = "ride", off: Bool = false, km: Double? = nil) -> ChargeRide {
        let start = t0 + Int64(hours * 3_600_000)
        return ChargeRide(id: id, startAt: start, endAt: start + 1_800_000, kind: kind, isSimulated: sim, startRestPct: from, endRestPct: to,
                          lastLivePct: live, usedPct: used, endedByScooterOff: off, distanceM: km.map { $0 * 1000 })
    }

    func test_chargeFoundFromRestedJump() {
        // ride a ends at 40% rested; the next ride starts at 86%: +46% charged between the two
        let c = ChargeDetector.detect([ride("b", hours: 20, from: 86, to: 70), ride("a", hours: 0, from: 85, to: 40)])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].afterRideId, "a")
        XCTAssertEqual(c[0].beforeRideId, "b")
        XCTAssertEqual(c[0].fromPct, 40)
        XCTAssertEqual(c[0].toPct, 86)
        XCTAssertEqual(c[0].chargedPct, 46)
        XCTAssertEqual(c[0].windowStartAt, t0 + 1_800_000)
        XCTAssertEqual(c[0].windowEndAt, t0 + 20 * 3_600_000)
        XCTAssertFalse(c[0].inferredWhileAway)
        XCTAssertFalse(c[0].startedByShutdownFlag)
    }

    func test_smallRisesAreIgnored_threePointsCounts() {
        XCTAssertTrue(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: 40), ride("b", hours: 5, from: 42.9, to: 30)]).isEmpty)
        XCTAssertEqual(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: 40), ride("b", hours: 5, from: 43, to: 30)]).count, 1)
        // a lower start is never a charge
        XCTAssertTrue(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: 40), ride("b", hours: 5, from: 38, to: 30)]).isEmpty)
    }

    func test_endFromPredictedOrLive_whenNoRestedEnd() {
        // predicted end = start − used = 85 − 45 = 40; next 44 = +4 → charge
        XCTAssertEqual(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: nil, used: 45), ride("b", hours: 5, from: 44, to: nil)]).count, 1)
        // only the live % (reads low under load): 50 → 58 is sag recovery, 50 → 62 is a charge
        XCTAssertTrue(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: nil, live: 50), ride("b", hours: 5, from: 58, to: nil)]).isEmpty)
        XCTAssertEqual(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: nil, live: 50), ride("b", hours: 5, from: 62, to: nil)]).count, 1)
        // nothing to go on: no charge claimed
        XCTAssertTrue(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: nil), ride("b", hours: 5, from: 99, to: nil)]).isEmpty)
    }

    func test_shutdownFlagAndAway_andSimulatedNeverMix() {
        let c = ChargeDetector.detect([ride("a", hours: 0, from: 85, to: nil, live: 30, off: true), ride("b", hours: 100, from: 100, to: 90)])
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].startedByShutdownFlag)
        XCTAssertFalse(c[0].inferredWhileAway, "switched itself off: a charge window, not 'away'")
        let away = ChargeDetector.detect([ride("a", hours: 0, from: 85, to: 23), ride("b", hours: 24 * 5, from: 100, to: 90)])
        XCTAssertTrue(away[0].inferredWhileAway)
        // a simulated ride between two real ones is not paired with them
        let mixed = ChargeDetector.detect([ride("a", hours: 0, from: 85, to: 40), ride("s", hours: 2, from: 99, to: 90, sim: true), ride("b", hours: 5, from: 41, to: 30)])
        XCTAssertTrue(mixed.isEmpty)
        // discarded pieces are skipped
        XCTAssertTrue(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: 40), ride("d", hours: 1, from: 99, to: 98, kind: "discarded"), ride("b", hours: 5, from: 41, to: 30)]).isEmpty)
    }

    func test_severalChargesBetweenTwoRides_areOneRow() {
        // one pair of rides → at most one row, however many times it was plugged in
        XCTAssertEqual(ChargeDetector.detect([ride("a", hours: 0, from: 85, to: 20), ride("b", hours: 72, from: 100, to: 80)]).count, 1)
    }

    func test_cycles_isTheLargerOfChargedAndUsed() {
        let rides = [ride("a", hours: 0, from: 90, to: 40, used: 50), ride("b", hours: 20, from: 90, to: 40, used: 50), ride("s", hours: 30, from: 90, to: 10, used: 80, sim: true)]
        let charges = ChargeDetector.detect(rides)
        XCTAssertEqual(charges.map(\.chargedPct), [50])
        // used 100% = 1.0 cycle, charged 50% = 0.5 → 1.0; the simulated ride counts for nothing
        XCTAssertEqual(ChargeCycles.equivalent(charges: charges, rides: rides), 1.0, accuracy: 1e-9)
        // charged more than used (rested drop under-counts): charged wins
        let more = [DetectedCharge(id: "c", afterRideId: "a", beforeRideId: "b", fromPct: 10, toPct: 100, windowStartAt: 0, windowEndAt: 1,
                                   startedByShutdownFlag: false, inferredWhileAway: true, isSimulated: false)]
        XCTAssertEqual(ChargeCycles.equivalent(charges: more, rides: [ride("a", hours: 0, from: 90, to: 80, used: 10)]), 0.9, accuracy: 1e-9)
    }

    private func healthRides(_ n: Int, spanDays: Int, km100First: Double, km100Last: Double) -> [ChargeRide] {
        (0..<n).map { i in
            let t = Double(i) / Double(max(1, n - 1))
            let km100 = km100First + (km100Last - km100First) * (t < 0.5 ? 0 : 1)
            return ride("h\(i)", hours: t * Double(spanDays) * 24, from: 90, to: 50, used: 40, km: 40 * km100 / 100)
        }
    }

    func test_health_gate_20ridesAnd5cycles() {
        let few = healthRides(19, spanDays: 200, km100First: 70, km100Last: 70)
        XCTAssertEqual(BatteryHealth.evaluate(rides: few, cycles: 9), .gathering(cycles: 9, rides: 19))
        let enough = healthRides(20, spanDays: 200, km100First: 70, km100Last: 70)
        XCTAssertEqual(BatteryHealth.evaluate(rides: enough, cycles: 4.9), .gathering(cycles: 4.9, rides: 20))
        if case .health = BatteryHealth.evaluate(rides: enough, cycles: 5) {} else { XCTFail("gate met, 200 days of history") }
    }

    func test_health_isTheLatestThreeMonthsOverTheFirst() {
        let rides = healthRides(24, spanDays: 300, km100First: 80, km100Last: 72)
        guard case let .health(pct, now, first) = BatteryHealth.evaluate(rides: rides, cycles: 10) else { return XCTFail("health expected") }
        XCTAssertEqual(first, 80, accuracy: 1e-6)
        XCTAssertEqual(now, 72, accuracy: 1e-6)
        XCTAssertEqual(pct, 90, accuracy: 1e-6)
    }

    func test_health_shortHistoryIsABaseline() {
        let rides = healthRides(22, spanDays: 40, km100First: 80, km100Last: 80)
        guard case let .baseline(km) = BatteryHealth.evaluate(rides: rides, cycles: 12) else { return XCTFail("baseline expected") }
        XCTAssertEqual(km, 80, accuracy: 1e-6)
    }
}
