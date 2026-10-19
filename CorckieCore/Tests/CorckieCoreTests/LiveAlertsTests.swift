import XCTest
@testable import CorckieCore

/// P-4: the one place the live view may raise something. The battery levels, F-22 and the hot motor (plus plain data-state banners).
final class LiveAlertsTests: XCTestCase {
    func test_onlyTheThreeWarningsInterrupt() {
        XCTAssertEqual(LiveAlerts.interruptions, [.battery, .destination, .motorHot])
        XCTAssertEqual(LiveAlertKind.motorHot.banners, [.hot, .veryHot])
        XCTAssertTrue(LiveAlertKind.battery.banners.isEmpty && LiveAlertKind.destination.banners.isEmpty, "they speak, they show no banner")
        XCTAssertEqual(LiveAlert.battery(level: 20, kmLeft: 6).kind, .battery)
        XCTAssertEqual(LiveAlert.destination(name: "Work", verdict: .short(km: 2)).kind, .destination)
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
