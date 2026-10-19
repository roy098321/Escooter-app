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

    func test_mapHeight_isFixed_notDependingOnAnything_butTheScreen() {
        XCTAssertEqual(MapScreenLayout.mapHeight(screenHeight: 852), MapScreenLayout.mapHeight(screenHeight: 852))
    }
}
