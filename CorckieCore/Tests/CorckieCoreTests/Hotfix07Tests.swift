@testable import CorckieCore
import XCTest

/// Hotfix 111.291126.07 (audit of G2 leftovers, 24 Nov): the battery maths, sizes, climbs, G500 % and firmware baseline follow the
/// scooter's own model, not the G100's 16 Ah × 48 V pack. Synthetic numbers only.
final class Hotfix07Tests: XCTestCase {
    // MARK: A2 pack voltage

    func test_A2_prior_usesThePacksOwnVoltage() {
        let g500 = BatteryCalibration.prior(packAh: 21, packV: 60)
        XCTAssertEqual(g500.packWh, 1_260, accuracy: 1e-9, "21 Ah × 60 V")
        XCTAssertEqual(g500.whPerPct, 21 * 60 / 100 * T.t41PriorRawFactor, accuracy: 1e-9)
        let g100 = BatteryCalibration.prior()
        XCTAssertEqual(g100.packWh, 16 * 48, accuracy: 1e-9, "the G100 default is unchanged")
    }

    func test_A2_calibrate_judgesRidesAgainstThePacksOwnPrior() {
        // 12.6 Wh per point is normal on a 60 V 21 Ah pack, implausible-free; the factor stays near 1
        let rides = (0..<5).map { i in
            CalibrationRide(id: "r\(i)", startAt: Int64(i) * 1000, endAt: Int64(i) * 1000 + 600, kind: "ride", isSimulated: false,
                            energyWhRaw: 12.6 * 20, startRestPct: 90, endRestPct: 70, lastLivePct: 70, longestGapS: 0, distanceM: 8000)
        }
        let (cal, _) = BatteryCalibrator.calibrate(rides, packAh: 21, packV: 60)
        XCTAssertEqual(cal.status, .calibrated)
        XCTAssertEqual(cal.whPerPct, 12.6, accuracy: 0.01)
        XCTAssertEqual(cal.factor, 12.6 / 12.6, accuracy: 0.01, "factor against the 60 V pack, not 48 V")
    }

    func test_A2_learnedPack_readsTheG500As21Ah() {
        let cal = BatteryCalibration(packAh: 21, whPerPct: 12.6, measuredWhPerPct: 12.6, ridesUsed: 5, status: .calibrated, packV: 60)
        XCTAssertEqual(LearnedPack.line(cal, choices: ScooterModels.packChoices(model: "RND G500")), "21 Ah \u{00B7} learned from 5 rides")
    }

    func test_A2_packV_modelThenLearnedThen48() {
        XCTAssertEqual(ScooterModels.packV(model: "RND G500"), 60)
        XCTAssertEqual(ScooterModels.packV(model: "RND G100"), 48)
        XCTAssertEqual(ScooterModels.packV(model: "Other", learnedClassV: 52), 52)
        XCTAssertEqual(ScooterModels.packV(model: nil), T.t42PackVoltage)
    }

    // MARK: A3 sizes per model

    func test_A3_packChoices_perModel() {
        XCTAssertEqual(ScooterModels.packChoices(model: "RND G500"), [21])
        XCTAssertEqual(ScooterModels.packChoices(model: "RND G100"), [16, 15, 13])
        XCTAssertEqual(ScooterModels.packChoices(model: nil), [16, 15, 13])
    }

    // MARK: A4 climbs

    func test_A4_climbCeiling_followsTheScootersWhPerPoint() {
        // a 600 m climb, +10 m, the readings drop 4 points: at most ~31 Wh (40 Wh/km + the lift), +10 %
        let points = (0..<60).map { i in SeriesPoint(t: Double(i), batteryPct: i < 30 ? 80 : 76) }
        XCTAssertEqual(RideLayers.climbBatteryUsed(points, from: 0, to: 59, distM: 600, gainM: 10), 4, "G100 (7.68 Wh a point): 4.4 allowed")
        XCTAssertNil(RideLayers.climbBatteryUsed(points, from: 0, to: 59, distM: 600, gainM: 10, whPerPct: 12.6),
                     "G500 (12.6 Wh a point): 2.7 allowed, so 4 points is sag, hidden")
    }

    // MARK: A5 G500 % follows the rider's size

    private func packet(volts: Double, amps: Double = 0.03, raw: Int = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x24; b[1] = 0x20; b[2] = 0x12; b[3] = 0x34
        func put(_ i: Int, _ v: Int) { b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8((v >> 8) & 0xFF) }
        put(4, Int((volts * 100).rounded())); put(6, Int((amps * 100).rounded())); b[8] = 0x2C
        put(10, raw); put(14, 2500); b[16] = 1
        return b
    }

    private func drop(packAh: Double?) throws -> Int {
        var a = FrameAssembler()
        a.packAhOverride = packAh
        _ = a.ingest(packet(volts: 66.3), at: 0)
        let start = try XCTUnwrap(a.g500RestPct)
        var t = 0.0
        for _ in 0..<(12 * 60 * 3) {                 // 12 min at 30 A = 6 Ah
            t += 1.0 / 3
            _ = a.ingest(packet(volts: 59, amps: 30, raw: 900), at: t)
        }
        return start - (try XCTUnwrap(a.g500RestPct))
    }

    func test_A5_g500Pct_countsDownByTheRidersSize() throws {
        XCTAssertEqual(Double(try drop(packAh: nil)), 6.0 / 21 * 100, accuracy: 1, "no setting: the model's 21 Ah")
        XCTAssertEqual(Double(try drop(packAh: 30)), 6.0 / 30 * 100, accuracy: 1, "the rider's 30 Ah")
    }

    func test_A5_override_survivesADisconnect() {
        var a = FrameAssembler()
        a.packAhOverride = 30
        a.reset()
        XCTAssertEqual(a.packAhOverride, 30)
    }

    // MARK: A6 firmware baseline per model

    func test_A6_firmwareBaseline_onlyForTheModelItWasSeenOn() {
        XCTAssertEqual(ScooterModels.firmwareBaseline(model: "RND G100"), DeviceInfo.p2Baseline)
        XCTAssertNil(ScooterModels.firmwareBaseline(model: "RND G500"), "no G100 firmware warning on a G500")
        XCTAssertNil(ScooterModels.firmwareBaseline(model: nil))
    }
}
