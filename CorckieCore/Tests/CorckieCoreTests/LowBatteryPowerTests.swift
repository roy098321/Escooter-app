import XCTest
@testable import CorckieCore

/// LBP: learned only from rides below 15 %; the arrival time counts on slower riding below the limit.
final class LowBatteryPowerTests: XCTestCase {
    func testLearnsWhereThePowerIsHeldBack() throws {
        let l = try XCTUnwrap(LowBatteryPower.learn(LBPSamples.made(deep: true)))
        XCTAssertEqual(l.belowPct, 25)
        XCTAssertEqual(l.powerShare, 0.75, accuracy: 0.02)
        XCTAssertEqual(LowBatteryPower.line(l), "Below about 25% your scooter holds back power (about 75% of usual)")
    }

    func testNothingBeforeADeepRide() {
        XCTAssertNil(LowBatteryPower.learn(LBPSamples.made(deep: false)))
        XCTAssertEqual(LowBatteryPower.line(nil), "Low-battery power limit: not learned yet (needs a ride below 15%)")
        XCTAssertEqual(LowBatteryPower.timeFactor(batteryPct: 10, learned: nil), 1, "no change until learned")
    }

    func testArrivalTimeStretchesOnlyBelowTheLimit() {
        let l = LBPLearned(belowPct: 20, powerShare: 0.75)
        XCTAssertEqual(LowBatteryPower.timeFactor(batteryPct: 30, learned: l), 1)
        XCTAssertEqual(LowBatteryPower.timeFactor(batteryPct: 15, learned: l), 1 / pow(0.75, 1.0 / 3.0), accuracy: 1e-9)
        XCTAssertNotNil(LowBatteryPower.parse(LowBatteryPower.json(l)))
    }
}
