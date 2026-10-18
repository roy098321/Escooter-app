import XCTest
@testable import CorckieCore

/// M1-07: what the live view shows (speed + source, battery + "est.", SLOW hysteresis, chips, starting dot).
final class LiveStateTests: XCTestCase {
    func testSpeedWarningHysteresis() {
        var w = SpeedWarning()
        XCTAssertFalse(w.update(speedKmh: 47.9))
        XCTAssertFalse(w.update(speedKmh: 48.0))     // "above 48", not at 48
        XCTAssertTrue(w.update(speedKmh: 48.1))
        XCTAssertTrue(w.update(speedKmh: 46.0))      // clears only below 46
        XCTAssertFalse(w.update(speedKmh: 45.9))
        XCTAssertFalse(w.update(speedKmh: 47.9))     // and stays off until above 48 again
    }

    func testScooterSpeedAndBattery() {
        var b = LiveStateBuilder()
        let s = b.update(LiveInput(scooterSpeedKmh: 27.4, scooterBatteryPct: 91.2))
        XCTAssertEqual(s.speedKmh, 27)
        XCTAssertEqual(s.speedSource, .scooter)
        XCTAssertNil(s.speedLabel)
        XCTAssertFalse(s.speedGreyed)
        XCTAssertEqual(s.batteryText, "91%")
        XCTAssertFalse(s.batteryEstimated)
        XCTAssertFalse(s.slow)
        XCTAssertNil(s.slowText)
    }

    func testSlowOnScooterSpeedAndClears() {
        var b = LiveStateBuilder()
        XCTAssertFalse(b.update(LiveInput(scooterSpeedKmh: 47.9)).slow)
        let on = b.update(LiveInput(scooterSpeedKmh: 48.1))
        XCTAssertTrue(on.slow)
        XCTAssertEqual(on.slowText, "SLOW")
        XCTAssertTrue(b.update(LiveInput(scooterSpeedKmh: 46.0)).slow)
        XCTAssertFalse(b.update(LiveInput(scooterSpeedKmh: 45.9)).slow)
    }

    func testPhoneModeUsesGpsLabelGreyAndEstimate() {
        var b = LiveStateBuilder()
        let s = b.update(LiveInput(scooterSpeedKmh: nil, gpsSpeedKmh: 21.6, scooterLinked: false,
                                   scooterBatteryPct: 60, estimatedBatteryPct: 55.4))
        XCTAssertEqual(s.speedKmh, 22)
        XCTAssertEqual(s.speedSource, .gps)
        XCTAssertEqual(s.speedLabel, "GPS")
        XCTAssertTrue(s.speedGreyed)
        XCTAssertEqual(s.batteryText, "~55% est.")
        XCTAssertTrue(s.batteryEstimated)
    }

    func testGpsBelowFiveShowsZero() {
        var b = LiveStateBuilder()
        XCTAssertEqual(b.update(LiveInput(gpsSpeedKmh: 4.9, scooterLinked: false)).speedKmh, 0)
        XCTAssertEqual(b.update(LiveInput(gpsSpeedKmh: 5.0, scooterLinked: false)).speedKmh, 5)
    }

    func testSlowOnGpsSpeed() {
        var b = LiveStateBuilder()
        let s = b.update(LiveInput(gpsSpeedKmh: 49, scooterLinked: false))
        XCTAssertTrue(s.slow)
        XCTAssertEqual(s.speedLabel, "GPS")      // GPS label is always set in phone mode
        XCTAssertFalse(b.update(LiveInput(gpsSpeedKmh: 45.5, scooterLinked: false)).slow)
    }

    func testNoSpeedAtAllKeepsWarningState() {
        var b = LiveStateBuilder()
        _ = b.update(LiveInput(scooterSpeedKmh: 50))
        let s = b.update(LiveInput(scooterSpeedKmh: nil, gpsSpeedKmh: nil, scooterLinked: false))
        XCTAssertNil(s.speedKmh)
        XCTAssertTrue(s.slow)
        XCTAssertEqual(s.batteryText, "–")
    }

    func testScooterLinkedButStaleReadingFallsBackToGps() {
        var b = LiveStateBuilder()
        let s = b.update(LiveInput(scooterSpeedKmh: nil, gpsSpeedKmh: 18, scooterLinked: true, scooterBatteryPct: 80))
        XCTAssertEqual(s.speedSource, .gps)
        XCTAssertEqual(s.speedLabel, "GPS")
        XCTAssertEqual(s.batteryText, "80%")
    }

    func testChipsAndStartingDot() {
        var b = LiveStateBuilder()
        XCTAssertEqual(b.update(LiveInput(scooterSpeedKmh: 20, secondsWithoutGps: 9.9)).chips, [])
        XCTAssertEqual(b.update(LiveInput(scooterSpeedKmh: 20, secondsWithoutGps: 10)).chips, [.noGps])
        XCTAssertEqual(b.update(LiveInput(scooterSpeedKmh: 20, secondsWithoutGps: 30, mapOffline: true)).chips, [.noGps, .offlineMap])
        XCTAssertTrue(b.update(LiveInput(scooterSpeedKmh: 0, starting: true)).showStartingDot)
        XCTAssertFalse(b.update(LiveInput(scooterSpeedKmh: 0)).showStartingDot)
    }
}
