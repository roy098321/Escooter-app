import XCTest
@testable import CorckieCore

/// M1-11: Home states (STATES S1 / S2), the 30-s connect rule, pattern L wording, onboarding in 3 presses.
final class HomeLogicTests: XCTestCase {
    private let now = 1_790_000_000.0   // epoch seconds

    private func input(paired: Bool = true, connected: Bool = false, since: Double? = nil, ride: Bool = false) -> HomeInput {
        HomeInput(paired: paired, connected: connected, connectingSinceS: since, nowS: now, batteryPct: 91,
                  lastSeenMs: Int64((now - 3600) * 1000), lastSeenPct: 58, rideActive: ride)
    }

    func testFirstUseShowsConnectNotStartRide() {
        let m = HomeLogic.model(input(paired: false))
        XCTAssertEqual(m.state, .noScooter)
        XCTAssertEqual(m.primary, .connect)
        XCTAssertEqual(m.primaryTitle, "Connect your scooter")
        XCTAssertFalse(m.showLocationCard)
    }

    func testStartRideOnlyWhenConnected() {
        for connected in [false, true] {
            let m = HomeLogic.model(input(connected: connected))
            XCTAssertEqual(m.primary == .startRide, connected, "Start ride only with a confirmed connection")
        }
        let ready = HomeLogic.model(input(connected: true))
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.batteryText, "91%")
        XCTAssertFalse(ready.greyed)
    }

    func testNotConnectedIsGreyedLastSeenAndNeverSaysOff() {
        let m = HomeLogic.model(input())
        XCTAssertEqual(m.state, .notConnected)
        XCTAssertTrue(m.greyed)
        XCTAssertEqual(m.title, "Scooter not connected")
        XCTAssertTrue(m.detail.hasPrefix("last seen "))
        XCTAssertTrue(m.detail.hasSuffix("58%"))
        XCTAssertFalse((m.title + m.detail).lowercased().contains(" off"))
        XCTAssertNil(m.batteryText)
    }

    func testConnectFailsAfter30Seconds() {
        XCTAssertEqual(HomeLogic.model(input(since: now - 29.9)).state, .connecting)
        XCTAssertFalse(HomeLogic.model(input(since: now - 29.9)).primaryEnabled)
        let failed = HomeLogic.model(input(since: now - 30))
        XCTAssertEqual(failed.state, .cantFind)
        XCTAssertEqual(failed.title, "Can't find the scooter")
        XCTAssertEqual(failed.detail, "Is it switched on?")
        XCTAssertEqual(failed.primary, .tryAgain)
        // connecting later wins
        XCTAssertEqual(HomeLogic.model(input(connected: true, since: now - 60)).state, .ready)
    }

    func testRidingWinsAndOpensTheLiveView() {
        let m = HomeLogic.model(input(connected: true, ride: true))
        XCTAssertEqual(m.state, .riding)
        XCTAssertEqual(m.primary, .openRide)
        // phone mode: ride on, link down
        XCTAssertEqual(HomeLogic.model(input(connected: false, ride: true)).state, .riding)
    }

    func testLastSeenWording() {
        let seen = Int64(1_790_000_000_000)
        func text(_ ageH: Double) -> String {
            HomeLogic.lastSeenText(lastSeenMs: seen, pct: 58, nowMs: seen + Int64(ageH * 3_600_000), utcOffsetMin: 0)
        }
        // 1_790_000_000 s = 14:13:20 UTC
        XCTAssertEqual(text(2), "last seen 14:13 \u{00B7} 58%")
        XCTAssertEqual(text(23.9), "last seen 14:13 \u{00B7} 58%")
        XCTAssertEqual(text(24), "last seen yesterday \u{00B7} 58%")
        XCTAssertEqual(text(72), "last seen 3 days ago \u{00B7} 58%")
        XCTAssertEqual(HomeLogic.lastSeenText(lastSeenMs: nil, pct: nil, nowMs: seen, utcOffsetMin: 0), "never connected yet")
        XCTAssertEqual(HomeLogic.clock(seen, 180), "17:13")
        XCTAssertEqual(HomeLogic.clock(0, -60), "23:00")
    }

    func testCardsAndLastRide() {
        var i = input(connected: true)
        i.locationAlways = false
        i.lastRunCrashed = true
        i.lastRide = RideListItem(id: "r", startAt: 0, distanceM: 6100, totalS: 1080)
        let m = HomeLogic.model(i)
        XCTAssertTrue(m.showLocationCard)
        XCTAssertTrue(m.showCrashBanner)
        XCTAssertEqual(m.lastRideText, "Last ride \u{00B7} 6.1 km \u{00B7} 18 min")
        i.paired = false
        XCTAssertFalse(HomeLogic.model(i).showLocationCard, "no location card before a scooter is paired")
    }

    func testOnboardingIsThreePresses() {
        var f = OnboardingFlow()
        XCTAssertFalse(f.press(.connect), "Connect needs the scooter found")
        XCTAssertEqual(f.presses, 0)
        f.setScooterFound(true)
        XCTAssertTrue(f.canConnect)
        XCTAssertTrue(f.press(.connect))
        XCTAssertEqual(f.step, .location)
        XCTAssertFalse(f.press(.connect), "wrong press for this step")
        XCTAssertTrue(f.press(.allow))
        XCTAssertEqual(f.step, .notifications)
        XCTAssertTrue(f.press(.notNow))
        XCTAssertTrue(f.isDone)
        XCTAssertEqual(f.presses, 3)
        XCTAssertFalse(f.press(.allow), "nothing after Done")
    }

    func testOnboardingSetUpLaterLeavesWithoutPresses() {
        var f = OnboardingFlow()
        f.skipForNow()
        XCTAssertTrue(f.isDone)
        XCTAssertTrue(f.skipped)
        XCTAssertEqual(f.presses, 0)
        XCTAssertEqual(OnboardingFlow(scooterFound: true).stepText, "1 of 3")
    }
}
