import XCTest
@testable import CorckieCore

/// D2 7e: the battery size learned from the calibration
final class LearnedPackTests: XCTestCase {
    private func cal(_ status: BatteryCalibration.Status, measured: Double?, rides: Int, ah: Double = 16) -> BatteryCalibration {
        BatteryCalibration(packAh: ah, whPerPct: 8.3, measuredWhPerPct: measured, ridesUsed: rides, status: status)
    }

    func test_beforeCalibrationItSaysAssumed() {
        XCTAssertEqual(LearnedPack.line(cal(.prior, measured: nil, rides: 0)), "Assumed 16 Ah")
        XCTAssertEqual(LearnedPack.line(cal(.learning, measured: 8.3, rides: 3)), "Assumed 16 Ah")
    }

    func test_calibratedSnapsToACommonSize() {
        // 8.3 Wh per 1 % on 48 V is 17.3 Ah raw: 8 % above 16, so it snaps to 16
        XCTAssertEqual(LearnedPack.line(cal(.calibrated, measured: 8.3, rides: 5)), "16 Ah \u{00B7} learned from 5 rides")
        // a 13 Ah pack: 6.4 Wh per 1 %
        XCTAssertEqual(LearnedPack.line(cal(.calibrated, measured: 6.4, rides: 7, ah: 16)), "13 Ah \u{00B7} learned from 7 rides")
    }

    func test_farFromAnyCommonSizeRoundsToWholeAh() {
        XCTAssertEqual(LearnedPack.snapped(21.4), 21)
    }
}
