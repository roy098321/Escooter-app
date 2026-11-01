import XCTest
@testable import CorckieCore

/// Note 16: two-finger pinch = time zoom; one-finger swipe up / down = value scale (up = stretch); sideways = cursor / pan.
final class GraphGesturesTests: XCTestCase {
    func testADragIsToldApartOnce() {
        XCTAssertNil(RideGraph.dragAxis(dx: 3, dy: 4), "under 10 pt: not decided")
        XCTAssertEqual(RideGraph.dragAxis(dx: 2, dy: -14), .upDown)
        XCTAssertEqual(RideGraph.dragAxis(dx: 14, dy: 5), .sideways)
    }

    func testSwipeUpStretchesDownRelaxes() {
        XCTAssertGreaterThan(RideGraph.swipeScale(base: 1, dyFraction: -0.3), 1, "up = stretch")
        XCTAssertLessThan(RideGraph.swipeScale(base: 2, dyFraction: 0.3), 2, "down = relax")
        XCTAssertEqual(RideGraph.swipeScale(base: 3, dyFraction: 0), 3)
        XCTAssertEqual(RideGraph.swipeScale(base: 1, dyFraction: -10), 20, "clamped like the pinch")
        XCTAssertEqual(RideGraph.swipeScale(base: 1, dyFraction: 10), 0.5)
    }
}
