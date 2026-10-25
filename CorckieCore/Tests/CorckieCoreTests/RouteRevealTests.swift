import XCTest
@testable import CorckieCore

/// B53: the route draws itself smoothly: by distance, eased, a partial stretch at the front.
final class RouteRevealTests: XCTestCase {
    private func p(_ i: Double) -> GeoPoint { GeoPoint(lat: 10.0 + i * 0.000_3, lon: 20.0) }

    func testEndsFollowTheDistance() {
        // a short stretch then one three times longer
        let s = [ValueStretch(a: p(0), b: p(1), t: 0, value: 1), ValueStretch(a: p(1), b: p(4), t: 1, value: 1)]
        let ends = RouteReveal.ends(s)
        XCTAssertEqual(ends.count, 2)
        XCTAssertEqual(ends[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(ends[1], 1, accuracy: 0.000_1)
        XCTAssertEqual(RouteReveal.ends([]), [])
    }

    func testEasingIsSmoothAndEndsExactly() {
        XCTAssertEqual(RouteReveal.eased(0), 0)
        XCTAssertEqual(RouteReveal.eased(1), 1)
        XCTAssertEqual(RouteReveal.eased(0.5), 0.5, accuracy: 0.000_1)
        XCTAssertLessThan(RouteReveal.eased(0.1), 0.1, "slow start")
        // no jumps: each 1/120 s frame moves the front by a small step
        var last = 0.0
        for f in 1...120 {
            let v = RouteReveal.progress(elapsedS: Double(f) / 120)
            XCTAssertLessThan(v - last, 0.02)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
        XCTAssertEqual(last, 1)
    }

    func testVisibleHasAPartialFront() {
        let ends = [0.25, 0.5, 0.75, 1.0]
        let a = RouteReveal.visible(ends: ends, progress: 0.6)
        XCTAssertEqual(a.whole, 2)
        XCTAssertEqual(a.partial, 0.4, accuracy: 0.001)
        XCTAssertEqual(RouteReveal.visible(ends: ends, progress: 0).whole, 0)
        XCTAssertEqual(RouteReveal.visible(ends: ends, progress: 1).whole, 4)
        XCTAssertEqual(RouteReveal.visible(ends: [], progress: 0.5).whole, 0)
    }
}
