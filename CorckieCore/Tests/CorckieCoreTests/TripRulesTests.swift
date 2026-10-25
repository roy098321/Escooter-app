import XCTest
@testable import CorckieCore

/// F-39 "what is a ride" (note 7, flaws 1-7): legs of a trip with a destination merge into one ride to where it ended; no
/// destination = never merge; the open trip and "↻ Continue to …"; detours and too-short rides out of the estimates; the
/// stop-trim line; the widen offer. All on made-up places and rides.
final class TripRulesTests: XCTestCase {
    private func leg(_ id: String, dest: String? = "uni", end: String? = nil, start: (Double, Double)? = (10, 20),
                     endAt: (Double, Double)? = (10, 20), day: String = "2026-10-24") -> TripRules.Leg {
        TripRules.Leg(rideId: id, destinationPlaceId: dest, destinationName: dest.map { $0 == "uni" ? "Uni" : $0 }, endPlaceId: end,
                      startLat: start?.0, startLon: start?.1, endLat: endAt?.0, endLon: endAt?.1, dayKey: day)
    }

    func test_F39_stopHalfway_thenArrive_mergesTheLegsIntoOneRide() {
        let first = TripRules.afterRide(leg("a"), open: nil)
        XCTAssertNil(first.merge)
        let open = try? XCTUnwrap(first.open)
        XCTAssertEqual(open?.placeName, "Uni")
        XCTAssertEqual(open.map(TripRules.continueText), "\u{21BB} Continue to Uni")
        let second = TripRules.afterRide(leg("b", dest: nil, end: "uni"), open: first.open)
        XCTAssertEqual(second.merge, ["a", "b"], "ignoring the offer does not close the trip; arriving merges")
        XCTAssertNil(second.open)
    }

    func test_F39_threeLegs_andEndingAtAnotherSavedPlace() {
        var d = TripRules.afterRide(leg("a"), open: nil)
        d = TripRules.afterRide(leg("b"), open: d.open)
        XCTAssertEqual(d.open?.legIds, ["a", "b"])
        d = TripRules.afterRide(leg("c", end: "grandma"), open: d.open)
        XCTAssertEqual(d.merge, ["a", "b", "c"], "flaw 4: one ride to the place where it really ended")
    }

    func test_F39_noDestination_neverMerges() {
        let d = TripRules.afterRide(leg("a", dest: nil), open: nil)
        XCTAssertNil(d.open)
        XCTAssertNil(d.merge)
        XCTAssertNil(TripRules.afterRide(leg("a", dest: "uni", end: "grandma"), open: nil).open, "ended at another saved place: a normal ride there")
        XCTAssertNil(TripRules.afterRide(leg("a", dest: "uni", end: "uni"), open: nil).open, "arrived: nothing open")
    }

    func test_F39_tripCloses_onAnotherPick_atTheEndOfTheDay_orFarAway() {
        let open = TripRules.afterRide(leg("a"), open: nil).open
        XCTAssertNil(TripRules.picked(placeId: "home", open: open), "another destination closes it")
        XCTAssertNil(TripRules.picked(placeId: nil, open: open), "No destination closes it")
        XCTAssertEqual(TripRules.picked(placeId: "uni", open: open), open)
        XCTAssertNil(TripRules.offered(open, dayKey: "2026-10-25"), "end of day")
        XCTAssertNil(TripRules.afterRide(leg("b", end: "uni", day: "2026-10-25"), open: open).merge)
        XCTAssertNil(TripRules.afterRide(leg("b", end: "uni", start: (10.05, 20)), open: open).merge, "starts 5 km away: another trip")
    }

    func test_F39_detour_andTooShort_keepOutOfTheEstimates() {
        XCTAssertEqual(TripRules.usualDistanceM([8_000, 8_200, 8_100]), 8_100)
        XCTAssertEqual(TripRules.usualDistanceM([8_000, 9_000]), 8_000, "fewer than 3: the shortest so far")
        XCTAssertTrue(TripRules.isDetour(distanceM: 10_000, othersM: [8_000, 8_200, 8_100]))
        XCTAssertFalse(TripRules.isDetour(distanceM: 9_000, othersM: [8_000, 8_200, 8_100]), "not ≥ 1 km longer")
        XCTAssertFalse(TripRules.isDetour(distanceM: 3_000, othersM: [2_000, 2_100, 2_050]), "46 % longer but under 1 km: not a detour")
        XCTAssertTrue(TripRules.isTooShort(distanceM: 5_000, othersM: [8_000, 8_200, 8_100]))
        XCTAssertTrue(TripRules.feedsEstimates(distanceM: 5_000, othersM: [8_000, 8_200, 8_100], startedAtPlace: true))
        let rides = [8_000.0, 8_100, 8_200, 11_000].enumerated().map {
            RouteRideStats(rideId: "r\($0.offset)", startAt: Int64($0.offset), totalS: 1_200, distanceM: $0.element)
        }
        XCTAssertEqual(TripRules.estimateRides(rides).map(\.rideId), ["r0", "r1", "r2"], "the detour still counts as a ride, not for the estimate")
    }

    func test_F39_stopTrimLine_ownersWording() {
        XCTAssertEqual(TripRules.stopTrimLine(stopS: 25 * 60), "Includes a 25 min stop, trim it?")
        XCTAssertNil(TripRules.stopTrimLine(stopS: 20))
    }

    func test_F39_widenOffer() {
        XCTAssertTrue(TripRules.widenOffer(endDistancesM: [230, 260, 50], radiusM: 200))
        XCTAssertFalse(TripRules.widenOffer(endDistancesM: [230, 50, 900], radiusM: 200), "one ride is not enough; 900 m is not a bit outside")
        XCTAssertEqual(TripRules.widenRadius(endDistancesM: [230, 260], radiusM: 200, choices: [100, 200, 300, 500]), 300)
        XCTAssertNil(TripRules.widenRadius(endDistancesM: [230], radiusM: 200, choices: [300]))
        XCTAssertEqual(TripRules.widenText(placeName: "Uni"), "Your rides end a bit outside Uni. Widen it?")
    }

    func test_F39_openTripJSON() {
        let t = TripRules.OpenTrip(placeId: "uni", placeName: "Uni", legIds: ["a"], endLat: 1, endLon: 2, dayKey: "2026-10-24")
        XCTAssertEqual(TripRules.OpenTrip.parse(t.json), t)
        XCTAssertNil(TripRules.OpenTrip.parse("nope"))
    }
}
