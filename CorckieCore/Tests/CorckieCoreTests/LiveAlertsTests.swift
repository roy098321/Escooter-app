import XCTest
@testable import CorckieCore

/// P-4: the one place the live view may raise something. Today only the hot motor (plus plain data-state banners).
final class LiveAlertsTests: XCTestCase {
    func test_onlyTheHotMotorInterrupts() {
        XCTAssertEqual(LiveAlerts.interruptions, [.motorHot])
        XCTAssertEqual(LiveAlert.motorHot.banners, [.hot, .veryHot])
    }

    func test_allowedBanners() {
        for b in [LiveBanner.hot, .veryHot, .disconnected, .noGps, .phoneBatteryLow] {
            XCTAssertTrue(LiveAlerts.isAllowed(b), "\(b)")
        }
        for b in [LiveBanner.batteryTight, .returnCheck, .starting, .notRiding, .destination, .headwind] {
            XCTAssertFalse(LiveAlerts.isAllowed(b), "\(b) must not reach the live view")
        }
    }

    func test_feedRaisesHeatAndStatusOnly() {
        var q = BannerQueue()
        q.beginRide(messages: [])
        LiveAlerts.feed(&q, input: LiveInput(scooterSpeedKmh: 20, scooterTempC: 91), chips: [], at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 20)?.banner, .hot)
        var quiet = BannerQueue()
        quiet.beginRide(messages: [])
        LiveAlerts.feed(&quiet, input: LiveInput(scooterSpeedKmh: 52, scooterTempC: 50), chips: [], at: 0)
        XCTAssertNil(quiet.tick(at: 0, speedKmh: 52), "a high speed alone never raises anything")
        var gps = BannerQueue()
        gps.beginRide(messages: [])
        LiveAlerts.feed(&gps, input: LiveInput(scooterSpeedKmh: 20, secondsWithoutGps: 12), chips: [.noGps], at: 0)
        XCTAssertEqual(gps.tick(at: 1, speedKmh: 20)?.banner, .noGps)
    }
}
