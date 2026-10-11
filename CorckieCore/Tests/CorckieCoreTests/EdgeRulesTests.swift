import XCTest
@testable import CorckieCore

/// M6-06 (C28): phone battery, storage, the 7-day expiry, a changed clock, location turned off mid-ride.
final class EdgeRulesTests: XCTestCase {
    // MARK: Phone battery

    func testPhoneBatteryReducesBelow20AndSwitchesGpsOffBelow10() {
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 80, charging: false, lowPowerMode: false), .normal)
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 20, charging: false, lowPowerMode: false), .normal)
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 19, charging: false, lowPowerMode: false), .reduced)
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 10, charging: false, lowPowerMode: false), .reduced)
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 9, charging: false, lowPowerMode: false), .off)
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 0, charging: false, lowPowerMode: false), .off)
    }

    func testChargingKeepsFullGpsAndLowPowerModeReduces() {
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 5, charging: true, lowPowerMode: true), .normal)
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 60, charging: false, lowPowerMode: true), .reduced)
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: nil, charging: false, lowPowerMode: false), .normal, "unknown level changes nothing")
        XCTAssertEqual(PhoneBatteryPolicy.gps(pct: 5, charging: false, lowPowerMode: true), .off, "low battery beats Low Power Mode")
    }

    // MARK: Storage

    func testStorageLevelsAndNotice() {
        XCTAssertEqual(StoragePolicy.level(freeBytes: nil), .ok)
        XCTAssertEqual(StoragePolicy.level(freeBytes: 5_000_000_000), .ok)
        XCTAssertEqual(StoragePolicy.level(freeBytes: 999_000_000), .thin)
        XCTAssertEqual(StoragePolicy.level(freeBytes: 299_000_000), .warn)
        XCTAssertNil(StoragePolicy.homeNotice(.thin, freeBytes: 500_000_000), "only the warn level shows a card")
        XCTAssertTrue(StoragePolicy.homeNotice(.warn, freeBytes: 120_000_000)?.contains("120 MB") == true)
        let now: Int64 = 1_790_000_000_000
        XCTAssertNil(StoragePolicy.thinCutoffMs(.ok, nowMs: now))
        XCTAssertEqual(StoragePolicy.thinCutoffMs(.thin, nowMs: now), now - 14 * 86_400_000)
        XCTAssertEqual(StoragePolicy.thinCutoffMs(.warn, nowMs: now), now - 14 * 86_400_000)
    }

    // MARK: Expiry

    func testExpiryPlan() {
        let now: Int64 = 1_790_000_000_000
        let day: Int64 = 86_400_000
        XCTAssertEqual(AppExpiry.plan(expiryMs: nil, nowMs: now), .unknown)
        XCTAssertEqual(AppExpiry.plan(expiryMs: now + 5 * day, nowMs: now), .remind(atMs: now + 4 * day))
        XCTAssertEqual(AppExpiry.plan(expiryMs: now + day / 2, nowMs: now), .soon(hoursLeft: 12))
        XCTAssertEqual(AppExpiry.plan(expiryMs: now + day, nowMs: now), .soon(hoursLeft: 24), "the reminder time is now: tell on Home instead")
        XCTAssertEqual(AppExpiry.plan(expiryMs: now - 1, nowMs: now), .expired)
        XCTAssertNil(AppExpiry.homeNotice(.remind(atMs: now)))
        XCTAssertNil(AppExpiry.homeNotice(.unknown))
        XCTAssertTrue(AppExpiry.homeNotice(.soon(hoursLeft: 7))?.contains("7 h") == true)
        XCTAssertTrue(AppExpiry.homeNotice(.expired)?.contains("expired") == true)
    }

    // MARK: Clock

    func testClockGuardFollowsTheWallClockUntilItIsChanged() {
        let g = ClockGuard(wall: 1_000_000, mono: 500)
        XCTAssertEqual(g.now(mono: 560), 1_000_060, accuracy: 1e-9)
        XCTAssertFalse(g.isJump(wall: 1_000_060.4, mono: 560))
    }

    func testAClockSetForwardOrBackMidRideDoesNotMoveTheEngine() {
        let g = ClockGuard(wall: 1_000_000, mono: 500)
        // 60 s later the owner sets the clock forward by an hour
        XCTAssertTrue(g.isJump(wall: 1_000_060 + 3_600, mono: 560))
        XCTAssertEqual(g.offsetS(wall: 1_000_060 + 3_600, mono: 560), 3_600, accuracy: 1e-9)
        XCTAssertEqual(g.now(mono: 560), 1_000_060, accuracy: 1e-9, "the engine keeps its own timeline")
        // a GPS fix stamped with the new wall clock lands on the engine's timeline
        XCTAssertEqual(g.engineTime(ofWall: 1_000_058 + 3_600, wall: 1_000_060 + 3_600, mono: 560), 1_000_058, accuracy: 1e-9)
        // set back by 10 minutes
        XCTAssertEqual(g.offsetS(wall: 1_000_060 - 600, mono: 560), -600, accuracy: 1e-9)
        XCTAssertTrue(g.isJump(wall: 1_000_060 - 600, mono: 560))
    }

    func testReanchorAdoptsTheNewWallClock() {
        var g = ClockGuard(wall: 1_000_000, mono: 500)
        g.reanchor(wall: 1_003_660, mono: 560)
        XCTAssertFalse(g.isJump(wall: 1_003_665, mono: 565))
        XCTAssertEqual(g.now(mono: 565), 1_003_665, accuracy: 1e-9)
    }

    // MARK: Live screen: phone battery banner and location turned off

    private func feed(_ input: LiveInput) -> LiveScreenState {
        var d = LiveScreenDriver()
        _ = d.update(input, at: 1)
        return d.update(input, at: 2)
    }

    func testPhoneBatteryBannerReplacesNoGps() {
        var input = LiveInput(scooterSpeedKmh: 20, scooterBatteryPct: 70, secondsWithoutGps: 30, phoneGpsOff: true)
        input.rideElapsedS = 60
        let s = feed(input)
        XCTAssertEqual(s.banner?.banner, .phoneBatteryLow)
        XCTAssertEqual(s.bannerText, "Phone battery low \u{00B7} map paused")
        // the speed and battery tiles are untouched
        XCTAssertEqual(s.tiles.speedKmh, 20)
    }

    func testNoGpsWithLocationTurnedOffSaysSo() {
        var input = LiveInput(scooterSpeedKmh: 20, scooterBatteryPct: 70, secondsWithoutGps: 30, locationDenied: true)
        input.rideElapsedS = 60
        let s = feed(input)
        XCTAssertEqual(s.banner?.banner, .noGps)
        XCTAssertEqual(s.bannerText, "No GPS \u{00B7} location is off for CorckieApp")
        // without the permission problem it stays the plain wording
        input.locationDenied = false
        XCTAssertEqual(feed(input).bannerText, "No GPS")
    }

    func testPhoneBatteryBannerRanksBelowDisconnectedAndStaysSticky() {
        var q = BannerQueue()
        q.setActive(.phoneBatteryLow, true, at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 20)?.banner, .phoneBatteryLow)
        XCTAssertEqual(q.tick(at: 60, speedKmh: 20)?.banner, .phoneBatteryLow, "no 8 s limit")
        q.setActive(.disconnected, true, at: 61)
        XCTAssertEqual(q.tick(at: 61, speedKmh: 20)?.banner, .disconnected)
        XCTAssertTrue(LiveBanner.disconnected < LiveBanner.phoneBatteryLow)
        XCTAssertTrue(LiveBanner.phoneBatteryLow < LiveBanner.hot)
    }
}
