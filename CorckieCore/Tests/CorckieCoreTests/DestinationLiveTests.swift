import XCTest
@testable import CorckieCore

/// F-35: "Riding to Uni, 8 km." once a few seconds after the start, again at once after a change at a stop; the tap opens the picker only
/// when stopped. Made-up names and distances only.
final class DestinationLiveTests: XCTestCase {
    func test_F35_lineAndKmText() {
        XCTAssertEqual(DestinationLive.ridingLine(name: "Uni", distanceM: 8_040), "Riding to Uni, 8 km.")
        XCTAssertEqual(DestinationLive.ridingLine(name: "B", distanceM: 2_960), "Riding to B, 3 km.")
        XCTAssertEqual(DestinationLive.ridingLine(name: "Shop", distanceM: 1_460), "Riding to Shop, 1.5 km.")
        XCTAssertEqual(DestinationLive.ridingLine(name: "Gym", distanceM: 12_600), "Riding to Gym, 13 km.")
        XCTAssertEqual(DestinationLive.ridingLine(name: "Uni", distanceM: nil), "Riding to Uni.")
        XCTAssertEqual(DestinationLive.kmText(400), "0.4 km")
    }

    func test_F35_announcedOnceAfterTheStart_andAtOnceAfterAChange() {
        var a = DestinationAnnouncer()
        XCTAssertFalse(a.update(riding: false, key: "uni", at: 0), "nothing before riding")
        XCTAssertFalse(a.update(riding: true, key: "uni", at: 10))
        XCTAssertFalse(a.update(riding: true, key: "uni", at: 14))
        XCTAssertTrue(a.update(riding: true, key: "uni", at: 15), "5 s after riding began")
        XCTAssertFalse(a.update(riding: true, key: "uni", at: 16), "once")
        XCTAssertTrue(a.update(riding: true, key: "place:b", at: 300), "a change during the ride is said at once")
        XCTAssertFalse(a.update(riding: true, key: "place:b", at: 301))
        XCTAssertFalse(a.update(riding: true, key: nil, at: 400), "clearing the destination says nothing")
        XCTAssertFalse(a.update(riding: false, key: nil, at: 500))
        XCTAssertFalse(a.update(riding: true, key: "uni", at: 600), "a new ride starts over")
        XCTAssertTrue(a.update(riding: true, key: "uni", at: 605))
    }

    func test_F35_noDestination_saysNothing_untilOneIsPicked() {
        var a = DestinationAnnouncer()
        for t in 0..<20 { XCTAssertFalse(a.update(riding: true, key: nil, at: Double(t))) }
        XCTAssertTrue(a.update(riding: true, key: "place:uni", at: 60), "picked at a stop (B62 Where to?): said at once")
    }

    func test_F35_changeOnlyWhenStopped() {
        XCTAssertTrue(DestinationLive.canChange(speedKmh: 0))
        XCTAssertTrue(DestinationLive.canChange(speedKmh: 2))
        XCTAssertFalse(DestinationLive.canChange(speedKmh: 3))
        XCTAssertFalse(DestinationLive.canChange(speedKmh: nil), "unknown speed counts as moving")
        XCTAssertEqual(DestinationLive.stopToChange, "Stop to change")
    }

    func test_F35_distance_routeLeftElseStraightLine() {
        let p = RouteLiveProgress(name: "Uni", routeKm: 8, alongKm: 3)
        XCTAssertEqual(DestinationLive.distanceM(progress: p, position: nil, end: nil) ?? 0, 5_000, accuracy: 0.001)
        let d = DestinationLive.distanceM(progress: nil, position: GeoPoint(lat: 10, lon: 20), end: GeoPoint(lat: 10.01, lon: 20)) ?? 0
        XCTAssertEqual(d, 1_112, accuracy: 5)
        XCTAssertNil(DestinationLive.distanceM(progress: nil, position: nil, end: GeoPoint(lat: 10, lon: 20)))
    }
}
