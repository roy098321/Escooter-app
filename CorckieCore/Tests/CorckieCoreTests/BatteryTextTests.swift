import XCTest
@testable import CorckieCore

/// M3-04: the Battery page words.
final class BatteryTextTests: XCTestCase {
    func test_calibrationStatus() {
        XCTAssertEqual(BatteryText.calibrationStatus(.prior()), "Not started, using the 16 Ah pack until the first good ride")
        let learning = BatteryCalibration(packAh: 16, whPerPct: 8.27, measuredWhPerPct: 8.35, ridesUsed: 3, status: .learning)
        XCTAssertEqual(BatteryText.calibrationStatus(learning), "Learning, 3 of 5 rides")
        XCTAssertEqual(BatteryText.calibrationValue(learning), "8.3 Wh per 1% (about 827 Wh usable)")
        let done = BatteryCalibration(packAh: 16, whPerPct: 8.4, measuredWhPerPct: 8.4, ridesUsed: 7, status: .calibrated)
        XCTAssertEqual(BatteryText.calibrationStatus(done), "Calibrated on 7 rides")
    }

    func test_chargeLine() {
        XCTAssertEqual(BatteryText.chargeLine(fromPct: 40, toPct: 86, away: false, start: "Tue 18:10", end: "Wed 08:05"),
                       "+46% charged between Tue 18:10 and Wed 08:05")
        XCTAssertEqual(BatteryText.chargeLine(fromPct: 23, toPct: 100, away: true, start: "", end: ""), "Charged while away · 23% → 100% · time unknown")
    }

    func test_healthWords() {
        let g = BatteryHealth.State.gathering(cycles: 2.14, rides: 1)
        XCTAssertEqual(BatteryText.healthTitle(g), "Gathering data")
        XCTAssertEqual(BatteryText.healthDetail(g), "Needs 5 charge cycles and 20 rides. So far 2.1 cycles and 1 ride.")
        XCTAssertEqual(BatteryText.healthTitle(.baseline(kmPer100: 80)), "Baseline forming")
        XCTAssertEqual(BatteryText.healthTitle(.health(pct: 91.6, kmPer100Now: 73, kmPer100First: 80)), "92%")
        XCTAssertTrue(BatteryText.healthDetail(.health(pct: 91.6, kmPer100Now: 73, kmPer100First: 80)).hasSuffix("Since tracking started."))
    }
}
