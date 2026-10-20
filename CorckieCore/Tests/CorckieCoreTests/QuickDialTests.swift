import XCTest
@testable import CorckieCore

/// P6-4 chunk 2: F-29 quick dial, B31 places as destinations, B34 parked newest-wins, B35 odometer gap (all on made-up numbers).
final class QuickDialTests: XCTestCase {
    func test_gridHas16DistinctSymbols() {
        XCTAssertEqual(PlaceIcon.symbols.count, 16)
        XCTAssertEqual(Set(PlaceIcon.symbols).count, 16)
    }

    func test_iconCodesRoundTrip() {
        XCTAssertEqual(PlaceIcon.parse(PlaceIcon.symbol("house").code), .symbol("house"))
        XCTAssertEqual(PlaceIcon.parse("tx:ma"), .letters("MA"))
        XCTAssertNil(PlaceIcon.parse("sf:not.a.symbol"))
        XCTAssertNil(PlaceIcon.parse("tx:"))
        XCTAssertNil(PlaceIcon.parse(nil))
    }

    func test_lettersAreOneOrTwoAndNoEmoji() {
        XCTAssertEqual(PlaceIcon.clean("maya"), "MA")
        XCTAssertEqual(PlaceIcon.clean(" a "), "A")
        XCTAssertEqual(PlaceIcon.clean("\u{1F600}x"), "X")
        XCTAssertEqual(PlaceIcon.clean("\u{05D0}\u{05D1}"), "\u{05D0}\u{05D1}")
        XCTAssertEqual(PlaceIcon.automatic(name: "Maya's house"), .letters("M"))
        XCTAssertEqual(PlaceIcon.automatic(name: nil), .letters("?"))
    }

    func test_slotsPinnedFirstThenMostVisited() {
        let places = [
            QuickDialPlace(id: "a", name: "Work", visits: 9),
            QuickDialPlace(id: "b", name: "Home", visits: 20),
            QuickDialPlace(id: "c", name: "Gym", visits: 2, pinOrder: 1),
            QuickDialPlace(id: "d", name: nil, visits: 50),
            QuickDialPlace(id: "e", name: "Never", visits: 0)
        ]
        XCTAssertEqual(QuickDial.slots(places, count: 3), ["c", "b", "a"])
        XCTAssertEqual(QuickDial.slots(places, count: 2), ["c", "b"])
        XCTAssertEqual(QuickDial.slots([], count: 3), [])
        XCTAssertEqual(QuickDial.slotCount(accessibilitySize: true), 2)
        XCTAssertEqual(QuickDial.slotCount(accessibilitySize: false), 3)
    }

    func test_tiesGoToTheOlderIdSoTheOrderNeverFlickers() {
        let places = [QuickDialPlace(id: "z", name: "Z", visits: 4), QuickDialPlace(id: "m", name: "M", visits: 4)]
        XCTAssertEqual(QuickDial.slots(places, count: 3), ["m", "z"])
    }

    func test_summaryLineAlwaysSaysWhatWasChosen() {
        XCTAssertEqual(QuickDial.summary(name: nil, minutes: nil, needPct: nil), "No destination")
        XCTAssertEqual(QuickDial.summary(name: "Maya's house", minutes: 12, needPct: 9), "Maya's house \u{00B7} 12 min \u{00B7} needs ~9 %")
        XCTAssertEqual(QuickDial.summary(name: "Gym", minutes: nil, needPct: nil), "Gym")
    }

    func test_placeDestinationFromStraightLine() throws {
        // 3 km at 5 m/s = 10 min; 3 km at 3 %/km = 9 %
        let e = try XCTUnwrap(PlaceDestination.estimate(distanceM: 3000, usualMps: 5, usualPctPerKm: 3))
        XCTAssertEqual(e.minutes, 10)
        XCTAssertEqual(e.usedPct ?? 0, 9, accuracy: 1e-9)
        // no rides: the fallback speed, no battery figure
        let f = try XCTUnwrap(PlaceDestination.estimate(distanceM: 550, usualMps: nil, usualPctPerKm: nil))
        XCTAssertEqual(f.timeS, 100, accuracy: 1e-9)
        XCTAssertNil(f.usedPct)
        XCTAssertNil(PlaceDestination.estimate(distanceM: nil, usualMps: 5, usualPctPerKm: 3))
        // the F-22 margin is applied by the warning, on the honest 9 %: 9 x 1.1 + reserve
        XCTAssertNil(DestinationRules.preRideWarning(name: "Gym", usualNeedPct: 9, batteryPct: 60))
        XCTAssertNotNil(DestinationRules.preRideWarning(name: "Gym", usualNeedPct: 9, batteryPct: 12))
    }

    func test_usualSpeedIsTheMedianOfRides() {
        let rides = [
            RouteRideStats(rideId: "1", startAt: 0, avgMovingMps: 4),
            RouteRideStats(rideId: "2", startAt: 0, avgMovingMps: 6),
            RouteRideStats(rideId: "3", startAt: 0, avgMovingMps: 5),
            RouteRideStats(rideId: "4", startAt: 0, avgMovingMps: 9, excluded: true)
        ]
        XCTAssertEqual(PlaceDestination.usualMps(rides), 5)
        XCTAssertNil(PlaceDestination.usualMps([]))
    }

    func test_odometerGap() {
        XCTAssertEqual(OdometerGap.km(connectKm: 104.2, lastRideEndKm: 100, lastGapToKm: nil) ?? 0, 4.2, accuracy: 1e-9)
        XCTAssertNil(OdometerGap.km(connectKm: 100.2, lastRideEndKm: 100, lastGapToKm: nil), "0.2 km is rounding, not a gap")
        XCTAssertNil(OdometerGap.km(connectKm: 104.2, lastRideEndKm: 100, lastGapToKm: 104.2), "a gap already noted is not noted twice")
        XCTAssertEqual(OdometerGap.km(connectKm: 110, lastRideEndKm: 100, lastGapToKm: 104.2) ?? 0, 5.8, accuracy: 1e-9)
        XCTAssertNil(OdometerGap.km(connectKm: 104, lastRideEndKm: nil, lastGapToKm: nil), "no recorded odometer, no verdict")
        XCTAssertNil(OdometerGap.km(connectKm: nil, lastRideEndKm: 100, lastGapToKm: nil))
        XCTAssertNil(OdometerGap.km(connectKm: 90, lastRideEndKm: 100, lastGapToKm: nil), "a lower odometer is no gap")
        XCTAssertEqual(OdometerGap.homeLine(km: 4.2), "4.2 km ridden without recording")
        XCTAssertEqual(OdometerGap.rideRow(km: 4.2), "Not recorded \u{00B7} 4.2 km")
    }

    func test_lastSeenFixMustBeGoodAndFresh() {
        XCTAssertTrue(LastSeenSpot.fixUsable(accuracyM: 30, ageS: 60))
        XCTAssertFalse(LastSeenSpot.fixUsable(accuracyM: 80, ageS: 10))
        XCTAssertFalse(LastSeenSpot.fixUsable(accuracyM: 10, ageS: 300))
        XCTAssertFalse(LastSeenSpot.fixUsable(accuracyM: -1, ageS: 10))
    }

    func test_parkedNewestWins() {
        let hour: Int64 = 3_600_000
        let now: Int64 = 1_790_000_000_000
        let ride = ParkedSpot(lat: 1, lon: 1, endedAtMs: now - 5 * hour, placeName: "Work")
        let seenNew = LastSeenSpot(lat: 2, lon: 2, atMs: now - 2 * hour, odoKm: 100)
        let seenOld = LastSeenSpot(lat: 3, lon: 3, atMs: now - 9 * hour, odoKm: 90)
        let a = ParkedChoice.choose(ride: ride, seen: seenNew, rideEndOdoKm: 90, currentOdoKm: 100)
        XCTAssertEqual(a?.lat, 2)
        XCTAssertEqual(a.map { ParkedText.line($0, nowMs: now) }, "Last seen here \u{00B7} 2 h ago")
        let b = ParkedChoice.choose(ride: ride, seen: seenOld, rideEndOdoKm: 90, currentOdoKm: 90)
        XCTAssertEqual(b?.lat, 1)
        XCTAssertEqual(b.map { ParkedText.line($0, nowMs: now) }, "Parked \u{00B7} Work \u{00B7} 5 h ago")
        XCTAssertEqual(ParkedChoice.choose(ride: nil, seen: seenOld, rideEndOdoKm: nil, currentOdoKm: nil)?.lat, 3)
        XCTAssertNil(ParkedChoice.choose(ride: nil, seen: nil, rideEndOdoKm: nil, currentOdoKm: nil))
    }

    func test_odometerAdvancedMeansLastSeenWithoutAConfidentPin() {
        let now: Int64 = 1_790_000_000_000
        let ride = ParkedSpot(lat: 1, lon: 1, endedAtMs: now - 3_600_000, placeName: "Work")
        let moved = ParkedChoice.choose(ride: ride, seen: nil, rideEndOdoKm: 100, currentOdoKm: 104)
        XCTAssertEqual(moved?.confident, false)
        XCTAssertEqual(moved.map { ParkedText.line($0, nowMs: now) }, "Last seen \u{00B7} Work \u{00B7} 1 h ago")
        let still = ParkedChoice.choose(ride: ride, seen: nil, rideEndOdoKm: 100, currentOdoKm: 100.1)
        XCTAssertEqual(still?.confident, true)
        let seen = LastSeenSpot(lat: 2, lon: 2, atMs: now, odoKm: 50)
        XCTAssertEqual(ParkedChoice.choose(ride: ride, seen: seen, rideEndOdoKm: 100, currentOdoKm: 55)?.confident, false)
    }
}
