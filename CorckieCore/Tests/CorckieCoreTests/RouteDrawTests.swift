import CorckieCore
import XCTest

/// N7-4 / N7-12 guard: one length curve shared by line, counters, sound and haptic; the haptic is silent at stops.
final class RouteDrawTests: XCTestCase {
    func test_N7_4_lengthCurve() {
        XCTAssertEqual(RouteDraw.durationS(km: 0), 0.6, accuracy: 0.001)
        XCTAssertEqual(RouteDraw.durationS(km: 2), 0.877, accuracy: 0.01)
        XCTAssertEqual(RouteDraw.durationS(km: 8), 1.244, accuracy: 0.01)
        XCTAssertEqual(RouteDraw.durationS(km: 30), 1.709, accuracy: 0.01)
        XCTAssertEqual(RouteDraw.durationS(km: 500), 1.8, accuracy: 0.001)
        XCTAssertEqual(RouteDraw.seenKey(rideId: "r1"), "routeDraw.seen.r1")
    }

    func test_N7_4_hapticFollowsSpeed_silentAtStops() {
        let i = RouteDraw.hapticIntensities(speedsKmh: [0, 10, 20, 0], steps: 4)
        XCTAssertEqual(i, [0, 0.5, 1, 0])
        XCTAssertTrue(RouteDraw.hapticIntensities(speedsKmh: [], steps: 5).isEmpty)
    }
}
