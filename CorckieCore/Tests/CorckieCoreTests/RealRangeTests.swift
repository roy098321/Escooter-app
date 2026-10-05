import XCTest
@testable import CorckieCore

/// M3-03: real range (M25) and charge time (M37) on made-up numbers.
final class RealRangeTests: XCTestCase {
    let cal = BatteryCalibration.prior()

    private func rides(_ n: Int, pctPerKm: Double, km: Double = 10, endPct: Double? = 40) -> [RangeRide] {
        (0..<n).map { RangeRide(startAt: Int64($0) * 86_400_000, distanceM: km * 1000, usedPct: pctPerKm * km, endPct: endPct) }
    }

    func test_range_isCurrentMinusReserveOverMyPctPerKm_andTheTextIsHonest() throws {
        let r = try XCTUnwrap(RealRangeCalc.compute(currentPct: 64, rides: rides(10, pctPerKm: 2.3), calibration: cal, reservePct: 5))
        XCTAssertEqual(r.pctPerKm, 2.3, accuracy: 1e-9)
        XCTAssertEqual(r.rangeKm, 59 / 2.3, accuracy: 1e-9)
        XCTAssertEqual(r.basedOnRides, 10)
        XCTAssertFalse(r.fromEnergy)
        XCTAssertFalse(r.lowBattery)
        XCTAssertEqual(r.text, "26 km from 64% at your recent 2.3%/km · based on your last 10 rides")
    }

    func test_decisionRange_carriesTheMargin_theShownRangeDoesNot() throws {
        let r = try XCTUnwrap(RealRangeCalc.compute(currentPct: 64, rides: rides(10, pctPerKm: 2.0), calibration: cal, reservePct: 4))
        XCTAssertEqual(r.rangeKm, 30, accuracy: 1e-9)
        XCTAssertEqual(r.decisionRangeKm, 60 / SafetyMargin.forDecision(2.0), accuracy: 1e-9)
        XCTAssertEqual(r.decisionRangeKm, 30 / 1.1, accuracy: 1e-9)
        XCTAssertTrue(r.fits(km: 27))
        XCTAssertFalse(r.fits(km: 28), "28 km fits the honest 30 km but not with the 10% margin")
    }

    func test_onlyTheNewest10RidesCount_simulatedAndShortHopsDoNot() throws {
        var all = rides(10, pctPerKm: 2.0)
        for i in 0..<6 { all.append(RangeRide(startAt: -Int64(i + 1) * 86_400_000, distanceM: 10_000, usedPct: 50)) }   // older, 5%/km
        all.append(RangeRide(startAt: 99 * 86_400_000, isSimulated: true, distanceM: 10_000, usedPct: 90))
        all.append(RangeRide(startAt: 98 * 86_400_000, kind: "shortHop", distanceM: 500, usedPct: 9))
        let r = try XCTUnwrap(RealRangeCalc.compute(currentPct: 50, rides: all, calibration: cal))
        XCTAssertEqual(r.pctPerKm, 2.0, accuracy: 1e-9)
        XCTAssertEqual(r.basedOnRides, 10)
    }

    func test_below20_usesRidesThatWentLow_andShowsATilde() throws {
        var all = rides(8, pctPerKm: 2.0, endPct: 50)
        all += [RangeRide(startAt: 100 * 86_400_000, distanceM: 10_000, usedPct: 30, endPct: 12),
                RangeRide(startAt: 101 * 86_400_000, distanceM: 10_000, usedPct: 34, endPct: 10)]
        let low = try XCTUnwrap(RealRangeCalc.compute(currentPct: 15, rides: all, calibration: cal, reservePct: 5))
        XCTAssertTrue(low.lowBattery)
        XCTAssertEqual(low.pctPerKm, 3.2, accuracy: 1e-9)
        XCTAssertEqual(low.basedOnRides, 2)
        XCTAssertTrue(low.text.hasPrefix("~3.1 km from 15%"), low.text)
        // no ride went low: the usual %/km, still with "~"
        let none = try XCTUnwrap(RealRangeCalc.compute(currentPct: 15, rides: rides(10, pctPerKm: 2.0), calibration: cal, reservePct: 5))
        XCTAssertEqual(none.pctPerKm, 2.0, accuracy: 1e-9)
        XCTAssertTrue(none.lowBattery)
    }

    func test_noRidesWithUsedPct_fallsBackToWhPerKmOverTheCalibration_andNothingAtAll_isNil() throws {
        let energyOnly = (0..<3).map { RangeRide(startAt: Int64($0) * 86_400_000, distanceM: 10_000, usedPct: nil, energyWhRaw: 160) }   // 16 Wh/km
        let r = try XCTUnwrap(RealRangeCalc.compute(currentPct: 50, rides: energyOnly, calibration: cal, reservePct: 5))
        XCTAssertTrue(r.fromEnergy)
        XCTAssertEqual(r.pctPerKm, 16 / cal.whPerPct, accuracy: 1e-9)
        XCTAssertTrue(r.text.contains("calibration"))
        XCTAssertNil(RealRangeCalc.compute(currentPct: 50, rides: [], calibration: cal))
        XCTAssertNil(RealRangeCalc.compute(currentPct: nil, rides: rides(10, pctPerKm: 2.0), calibration: cal))
        // a long scooter gap: its energy is too low to use
        let gappy = [RangeRide(startAt: 0, distanceM: 10_000, usedPct: nil, energyWhRaw: 160, gapScooterS: 300)]
        XCTAssertNil(RealRangeCalc.compute(currentPct: 50, rides: gappy, calibration: cal))
    }

    func test_belowReserve_isZeroKm() throws {
        let r = try XCTUnwrap(RealRangeCalc.compute(currentPct: 3, rides: rides(5, pctPerKm: 2.0), calibration: cal, reservePct: 5))
        XCTAssertEqual(r.rangeKm, 0)
    }

    func test_reserve_ranOutElse5() {
        XCTAssertEqual(RealRangeCalc.reservePct(ranOutJson: "{\"pct\":3,\"rideId\":\"x\"}"), 3)
        XCTAssertEqual(RealRangeCalc.reservePct(ranOutJson: nil), 5)
        XCTAssertEqual(RealRangeCalc.reservePct(ranOutJson: "garbage"), 5)
    }

    func test_chargeTime_steadyTo85ThenAnHour() {
        // 16 Ah, 2 A: 40% needs 0.45 x 16 / 2 = 3.6 h, then 1 h
        XCTAssertEqual(ChargeTime.hoursToFull(fromPct: 40, packAh: 16), 4.6, accuracy: 1e-9)
        XCTAssertEqual(ChargeTime.hoursToFull(fromPct: 85, packAh: 16), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ChargeTime.hoursToFull(fromPct: 92.5, packAh: 16), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ChargeTime.hoursToFull(fromPct: 100, packAh: 16), 0, accuracy: 1e-9)
        XCTAssertEqual(ChargeTime.hoursToFull(fromPct: 0, packAh: 16), 7.8, accuracy: 1e-9)
        XCTAssertEqual(ChargeTime.hoursToFull(fromPct: 40, packAh: 20), 0.45 * 10 + 1, accuracy: 1e-9)
    }

    func test_chargeTime_roundedToHalfHours_text() {
        XCTAssertEqual(ChargeTime.text(hours: 4.6), "~4.5 h")
        XCTAssertEqual(ChargeTime.text(hours: 7.8), "~8 h")
        XCTAssertEqual(ChargeTime.text(hours: 0.1), "~0.5 h")
        XCTAssertEqual(ChargeTime.text(hours: 0), "Full")
        XCTAssertEqual(ChargeTime.fullAt(endAtMs: 1_000, endPct: 40, packAh: 16), 1_000 + 4_500 * 3_600)
    }
}
