import XCTest
@testable import CorckieCore

/// M2-09: There and back (M27, T101 / G2: both legs carry the 10% margin, the reserve is 5%) and the ride-start warning (Q9).
final class ThereAndBackTests: XCTestCase {
    static let monday: Int64 = 20_717
    static let day: Int64 = 86_400_000
    static let now: Int64 = monday * day + 12 * 3_600_000

    private func rides(_ n: Int, used: Double?) -> [RouteRideStats] {
        (0..<n).map { i in
            RouteRideStats(rideId: "r\(i)", startAt: (Self.monday - Int64(i + 1)) * Self.day + 8 * 3_600_000, utcOffsetMin: 0,
                           totalS: 900, distanceM: 3_700, avgMovingMps: 7, usedPct: used)
        }
    }

    private func today(_ n: Int = 5, used: Double? = 10) -> TodayResult {
        TodayEstimator.estimate(rides: rides(n, used: used), nowMs: Self.now, utcOffsetMin: 0)
    }

    private func model(_ pct: Double, charge: Bool = false, there: TodayResult? = nil, back: TodayResult? = nil, age: Int? = nil) -> ThereAndBackModel? {
        ThereAndBack.model(there: there ?? today(), back: back ?? today(), battery: BatteryNow(pct: pct, ageMin: age), canChargeAtEnd: charge, destination: "Work")
    }

    func test_edges_atTenPercentSpare() throws {
        // each leg needs 10 x 1.10 = 11, reserve 5: the round trip needs 27
        let ok = try XCTUnwrap(model(37))
        XCTAssertEqual(ok.status, .fits)
        XCTAssertEqual(ok.symbol, "\u{2705}")
        XCTAssertEqual(ok.headline, "\u{2705} There and back fits")
        let tight = try XCTUnwrap(model(36.9))
        XCTAssertEqual(tight.status, .tight)
        XCTAssertEqual(tight.headline, "\u{26A0} Barely enough for a round trip")
        XCTAssertEqual(try XCTUnwrap(model(27)).status, .tight, "spare 0 is still tight")
        let way = try XCTUnwrap(model(26.9))
        XCTAssertEqual(way.status, .oneWayOnly)
        XCTAssertEqual(way.headline, "\u{274C} Not enough for the way back")
        let none = try XCTUnwrap(model(15.9))
        XCTAssertEqual(none.status, .notEnough)
        XCTAssertEqual(none.headline, "\u{274C} Not enough battery for the way there")
        XCTAssertEqual(try XCTUnwrap(model(16)).status, .oneWayOnly, "exactly enough for the way there")
    }

    func test_decisionsUseTheMargin_textsShowTheHonestNumber() throws {
        let m = try XCTUnwrap(model(40))
        XCTAssertTrue(m.detail.contains("there about 10%, back about 10%"), m.detail)
        XCTAssertFalse(m.detail.contains("11%"), "the margin is never shown as the estimate: \(m.detail)")
        XCTAssertTrue(m.detail.contains("Battery 40% now"), m.detail)
        XCTAssertTrue(m.detail.contains("about 13% to spare"), m.detail)
    }

    func test_canChargeAtTheEnd_onlyTheWayThereMustFit() throws {
        let fits = try XCTUnwrap(model(26, charge: true))
        XCTAssertEqual(fits.status, .fits)
        XCTAssertEqual(fits.headline, "\u{2705} Enough to get there")
        XCTAssertTrue(fits.detail.contains("you can charge at the end"))
        XCTAssertFalse(fits.detail.contains("back about"))
        XCTAssertEqual(try XCTUnwrap(model(25.9, charge: true)).status, .tight)
        XCTAssertEqual(try XCTUnwrap(model(15.9, charge: true)).status, .notEnough)
        // no way-back data needed with a charger
        XCTAssertEqual(try XCTUnwrap(model(30, charge: true, back: .notEnough(have: 0, need: 3))).status, .fits)
    }

    func test_gates_saySomethingOnlyWithData() {
        XCTAssertNil(model(50, there: today(4, used: 10)), "4 rides with a battery value: gate of 5")
        XCTAssertNil(model(50, there: today(2)), "fewer than 3 rides")
        XCTAssertNil(model(50, back: .notEnough(have: 2, need: 3)), "the way back is unknown and no charger")
        XCTAssertNil(ThereAndBack.model(there: today(), back: today(), battery: nil, canChargeAtEnd: false, destination: "Work"))
    }

    func test_lastSeenBatteryKeepsItsAge() throws {
        let m = try XCTUnwrap(model(30, age: 120))
        XCTAssertTrue(m.detail.contains("30% (2 h ago)"), m.detail)
    }

    func test_startWarning_oncePerStateAndOnlyWhenNeeded() throws {
        XCTAssertNil(ThereAndBack.startWarning(try XCTUnwrap(model(37))))
        XCTAssertEqual(ThereAndBack.startWarning(try XCTUnwrap(model(36.9))), "Battery 37%: just enough for Work and back.")
        XCTAssertEqual(ThereAndBack.startWarning(try XCTUnwrap(model(26.9))), "Battery 27%: enough for Work, not for the way back.")
        XCTAssertEqual(ThereAndBack.startWarning(try XCTUnwrap(model(15.9))), "Battery 16%: may not reach Work.")
    }

    // MARK: on the live screen

    private func follower() throws -> RouteFollower {
        let pts = (0..<31).map { GeoPoint(lat: 10 + Double($0) * 0.0009, lon: -30) }
        return try XCTUnwrap(RouteFollower(destinationName: "Work", path: pts, todayS: 540))
    }

    func test_liveScreen_warningShowsOnceAtRideStart() throws {
        let text = "Battery 27%: enough for Work, not for the way back."
        var d = LiveScreenDriver()
        d.follow(try follower(), utcOffsetMin: 0, returnWarning: text)
        func riding(_ t: Double) -> LiveScreenState {
            d.update(LiveInput(scooterSpeedKmh: 0, scooterBatteryPct: 27, phase: .riding, lat: 10.001, lon: -30, rideElapsedS: t, rideDistanceM: 0), at: t)
        }
        let first = riding(0)
        XCTAssertEqual(first.banner?.banner, .returnCheck)
        XCTAssertEqual(first.bannerText, text)
        // the banner leaves after its 8 s and does not come back
        var shownAgain = false
        for t in 9..<60 where riding(Double(t)).bannerText == text { shownAgain = true }
        XCTAssertFalse(shownAgain)
        // the next ride has no warning (the route choice and the warning end with the ride)
        _ = d.update(LiveInput(phase: .idle), at: 100)
        let next = d.update(LiveInput(scooterSpeedKmh: 0, scooterBatteryPct: 27, phase: .riding, rideElapsedS: 0), at: 200)
        XCTAssertNil(next.banner)
        XCTAssertNil(next.arrival)
    }

    func test_liveScreen_warningCountsInTheTwoStartMessages() throws {
        var q = BannerQueue()
        q.beginRide(messages: [.returnCheck, .destination, .headwind])
        XCTAssertEqual(q.waitingCount, 2)
        XCTAssertEqual(q.droppedToSummary.count, 1)
        XCTAssertEqual(LiveBanner.returnCheck.priority, LiveBanner.batteryTight.priority)
    }

    // MARK: route card

    func test_routeCard_hasTheCardOnlyWhenSavedAndWithABattery() {
        let there = rides(6, used: 10)
        func card(_ battery: BatteryNow?, state: RouteState = .saved) -> RouteCardModel {
            RouteCardBuilder.build(RouteCardInput(routeId: "a", fromName: "Home", toName: "Work", state: state, rides: there, otherDirection: there,
                                                  nowMs: Self.now, battery: battery))
        }
        XCTAssertEqual(card(BatteryNow(pct: 40)).thereAndBack?.status, .fits)
        XCTAssertNil(card(nil).thereAndBack)
        XCTAssertNil(card(BatteryNow(pct: 40), state: .suggested).thereAndBack)
        XCTAssertEqual(card(BatteryNow(pct: 20)).thereAndBack?.destination, "Work")
    }
}
