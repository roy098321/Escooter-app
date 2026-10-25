import XCTest
@testable import CorckieCore

/// B29: a fixed-height map on top, the numbers below in a normal scroll view.
final class MapScreenLayoutTests: XCTestCase {
    func test_mapHeight_isAShareOfTheScreen_withinLimits() {
        XCTAssertEqual(MapScreenLayout.mapHeight(screenHeight: 852), 340.8, accuracy: 0.01)     // iPhone 15
        XCTAssertEqual(MapScreenLayout.mapHeight(screenHeight: 932), 372.8, accuracy: 0.01)     // Pro Max
        XCTAssertEqual(MapScreenLayout.mapHeight(screenHeight: 1_200), 400)                     // never taller than the cap
    }

    func test_mapHeight_leavesRoomForTheScrollArea_onSmallPhones() {
        let small = MapScreenLayout.mapHeight(screenHeight: 667)
        XCTAssertEqual(small, 280, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(667 - small, MapScreenLayout.minScrollHeight)
        let tiny = MapScreenLayout.mapHeight(screenHeight: 500)
        XCTAssertGreaterThanOrEqual(500 - tiny, 200)
        XCTAssertGreaterThanOrEqual(tiny, 120)
    }

    /// B52: the ride review's map is ~55 % of the screen, the scroll area keeps its room
    func test_rideMapHeight_isAboutHalfTheScreen() {
        XCTAssertEqual(MapScreenLayout.rideMapHeight(screenHeight: 852), 468.6, accuracy: 0.01)    // iPhone 15
        XCTAssertEqual(MapScreenLayout.rideMapHeight(screenHeight: 932), 512.6, accuracy: 0.01)    // Pro Max
        XCTAssertEqual(MapScreenLayout.rideMapHeight(screenHeight: 667), 366.85, accuracy: 0.01)   // SE: the tiles keep 300 pt
        XCTAssertEqual(MapScreenLayout.rideMapHeight(screenHeight: 1_400), MapScreenLayout.rideMaxMapHeight)
        XCTAssertGreaterThan(MapScreenLayout.rideMapHeight(screenHeight: 852), MapScreenLayout.mapHeight(screenHeight: 852))
    }

    func test_bottomCover_movesThePathAboveTheCard() {
        let pts = [GeoPoint(lat: 10, lon: 20), GeoPoint(lat: 10.01, lon: 20.01)]
        let plain = MapFit.region(pts, padding: 0.1)!
        let covered = MapFit.region(pts, padding: 0.1, bottomCover: 0.45)!
        XCTAssertGreaterThan(covered.latSpan, plain.latSpan)
        XCTAssertLessThan(covered.centerLat, plain.centerLat, "the centre moves south so the path sits in the free top part")
        // the path's south end is still inside the uncovered part
        XCTAssertGreaterThan(10.0, covered.centerLat - covered.latSpan / 2 + covered.latSpan * 0.45 - 1e-9)
    }

    func test_mapHeight_isFixed_notDependingOnAnything_butTheScreen() {
        XCTAssertEqual(MapScreenLayout.mapHeight(screenHeight: 852), MapScreenLayout.mapHeight(screenHeight: 852))
    }
}
