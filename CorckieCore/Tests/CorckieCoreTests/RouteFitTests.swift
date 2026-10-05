import XCTest
@testable import CorckieCore

/// M2-05: Routes greying with the safety margin (M27, G2, T101), the battery shown with its age, the Places rows.
final class RouteFitTests: XCTestCase {
    static let monday: Int64 = 20_717
    static let day: Int64 = 86_400_000
    static let now: Int64 = monday * day + 12 * 3_600_000

    private func rides(_ n: Int, used: Double?, prefix: String = "r") -> [RouteRideStats] {
        (0..<n).map { i in
            RouteRideStats(rideId: "\(prefix)\(i)", startAt: (Self.monday - Int64(i + 1)) * Self.day + 8 * 3_600_000, utcOffsetMin: 0,
                           totalS: 900, distanceM: 3_700, avgMovingMps: 7, usedPct: used)
        }
    }

    // MARK: evaluate

    func test_oneWay_exactlyAtTheLimit_fits_andJustUnderIsGreyed() throws {
        // needed 11 (margin included) + reserve 5 = 16
        let exact = RouteFit.evaluate(thereNeededPct: 11, backNeededPct: nil, battery: BatteryNow(pct: 16))
        XCTAssertFalse(exact.greyed)
        XCTAssertEqual(exact.status, .noData, "no way-back data: nothing more is said")
        let under = RouteFit.evaluate(thereNeededPct: 11, thereUsedPct: 10, backNeededPct: nil, battery: BatteryNow(pct: 15.9))
        XCTAssertTrue(under.greyed)
        XCTAssertEqual(under.status, .notEnough)
        XCTAssertEqual(under.chip, "Not enough battery")
        XCTAssertEqual(try XCTUnwrap(under.sparePct), -0.1, accuracy: 1e-9)
    }

    func test_thereFits_backDoesNot_isOneWayOnly() {
        // there 11, back 11, reserve 5: the round trip needs 27
        let r = RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: BatteryNow(pct: 26.9))
        XCTAssertEqual(r.status, .oneWayOnly)
        XCTAssertEqual(r.chip, "One way only")
        XCTAssertFalse(r.greyed)
    }

    func test_roundTrip_tightBelowTenSpare_fitsAtTen() {
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: BatteryNow(pct: 27)).status, .tight, "spare 0")
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: BatteryNow(pct: 36.9)).status, .tight, "spare 9.9")
        let fits = RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: BatteryNow(pct: 37))
        XCTAssertEqual(fits.status, .fits, "spare exactly 10 (T82)")
        XCTAssertNil(fits.chip)
        XCTAssertFalse(fits.greyed)
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: BatteryNow(pct: 36.9)).chip, "Tight")
    }

    func test_canChargeAtTheEnd_onlyTheWayThereMustFit() {
        // 16 needed one way; the way back (huge) is ignored
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 40, battery: BatteryNow(pct: 15), canChargeAtEnd: true).status, .notEnough)
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 40, battery: BatteryNow(pct: 20), canChargeAtEnd: true).status, .tight)
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 40, battery: BatteryNow(pct: 26), canChargeAtEnd: true).status, .fits)
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: 11, backNeededPct: nil, battery: BatteryNow(pct: 26), canChargeAtEnd: true).status, .fits,
                       "no way-back data is not needed when you can charge")
    }

    func test_gate_noDataNoBattery_saysNothing() {
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: nil, backNeededPct: 11, battery: BatteryNow(pct: 5)), .silent)
        XCTAssertEqual(RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: nil), .silent)
        let noBack = RouteFit.evaluate(thereNeededPct: 11, backNeededPct: nil, battery: BatteryNow(pct: 40))
        XCTAssertNil(noBack.chip)
        XCTAssertFalse(noBack.greyed)
    }

    func test_scooterOff_usesTheLastSeenPercentWithItsAge() throws {
        XCTAssertEqual(BatteryNow(pct: 64).text, "64% now")
        XCTAssertEqual(BatteryNow(pct: 64, ageMin: 120).text, "64% (2 h ago)")
        XCTAssertEqual(RouteFit.ageText(minutes: 0), "1 min ago")
        XCTAssertEqual(RouteFit.ageText(minutes: 59), "59 min ago")
        XCTAssertEqual(RouteFit.ageText(minutes: 60), "1 h ago")
        XCTAssertEqual(RouteFit.ageText(minutes: 24 * 60), "1 day ago")
        XCTAssertEqual(RouteFit.ageText(minutes: 3 * 24 * 60 + 30), "3 days ago")
        let r = RouteFit.evaluate(thereNeededPct: 11, thereUsedPct: 10, backNeededPct: nil, battery: BatteryNow(pct: 12, ageMin: 120))
        XCTAssertEqual(r.status, .notEnough)
        XCTAssertTrue(try XCTUnwrap(r.detail).contains("12% (2 h ago)"))
    }

    // MARK: builder (the whole chain: Today, margin, reverse route)

    func test_list_marginDecidesButTheShownNumberIsHonest() throws {
        let saved = rides(6, used: 10)
        // honest 10% + 5% reserve = 15 would fit 15.5, but the decision uses 11 + 5 = 16
        let grey = RouteListBuilder.row(RouteListInput(routeId: "a", title: "A", state: .saved, rides: saved, nowMs: Self.now,
                                                       battery: BatteryNow(pct: 15.5)))
        XCTAssertTrue(grey.fit.greyed, "the 10% margin makes this one grey")
        XCTAssertTrue(try XCTUnwrap(grey.fit.detail).contains("about 10%"), "the number shown stays the honest estimate")
        let ok = RouteListBuilder.row(RouteListInput(routeId: "a", title: "A", state: .saved, rides: saved, nowMs: Self.now,
                                                     battery: BatteryNow(pct: 16.5)))
        XCTAssertFalse(ok.fit.greyed)
    }

    func test_list_thereFitsBackDoesNot_andGate() {
        let saved = rides(6, used: 10)
        let back = rides(6, used: 10, prefix: "b")
        let one = RouteListBuilder.row(RouteListInput(routeId: "a", title: "A", state: .saved, rides: saved, nowMs: Self.now,
                                                      reverseRides: back, battery: BatteryNow(pct: 25)))
        XCTAssertEqual(one.fit.chip, "One way only")
        let fits = RouteListBuilder.row(RouteListInput(routeId: "a", title: "A", state: .saved, rides: saved, nowMs: Self.now,
                                                       reverseRides: back, battery: BatteryNow(pct: 60)))
        XCTAssertEqual(fits.fit.status, .fits)
        XCTAssertNil(fits.fit.chip)

        // gate: 4 rides with a battery value (T67 needs 5) = nothing said, however empty the battery
        let few = RouteListBuilder.row(RouteListInput(routeId: "f", title: "F", state: .saved, rides: rides(4, used: 10), nowMs: Self.now,
                                                      battery: BatteryNow(pct: 2)))
        XCTAssertEqual(few.fit, .silent)
        // suggested routes are never judged; no battery reading = nothing said
        let sug = RouteListBuilder.row(RouteListInput(routeId: "s", title: "S", state: .suggested, rides: saved, nowMs: Self.now,
                                                      battery: BatteryNow(pct: 2)))
        XCTAssertEqual(sug.fit, .silent)
        let unknown = RouteListBuilder.row(RouteListInput(routeId: "u", title: "U", state: .saved, rides: saved, nowMs: Self.now, battery: nil))
        XCTAssertEqual(unknown.fit, .silent)
    }

    func test_list_canChargeAtTheEnd_ignoresTheWayBack() {
        let saved = rides(6, used: 10)
        let back = rides(6, used: 30, prefix: "b")
        let r = RouteListBuilder.row(RouteListInput(routeId: "a", title: "A", state: .saved, rides: saved, nowMs: Self.now,
                                                    reverseRides: back, battery: BatteryNow(pct: 40), canChargeAtEnd: true))
        XCTAssertEqual(r.fit.status, .fits)
    }

    // MARK: Places

    func test_places_rowTexts() {
        XCTAssertEqual(PlaceListBuilder.radiusText(nil), "Circle: automatic")
        XCTAssertEqual(PlaceListBuilder.radiusText(200), "Circle: 200 m")
        let a = PlaceListBuilder.row(id: "p", name: nil, radiusM: nil, canCharge: false, routeCount: 1)
        XCTAssertEqual(a.title, "Unnamed place")
        XCTAssertFalse(a.hasName)
        XCTAssertEqual(a.subtitle, "Circle: automatic \u{00B7} 1 route")
        let b = PlaceListBuilder.row(id: "q", name: "  Work ", radiusM: 300, canCharge: true, routeCount: 2)
        XCTAssertEqual(b.title, "Work")
        XCTAssertTrue(b.hasName)
        XCTAssertEqual(b.subtitle, "Circle: 300 m \u{00B7} you can charge here \u{00B7} 2 routes")
        XCTAssertEqual(PlaceListBuilder.radiusChoices.first, 100)
        XCTAssertEqual(PlaceListBuilder.radiusChoices.last, 1_000)
    }
}
