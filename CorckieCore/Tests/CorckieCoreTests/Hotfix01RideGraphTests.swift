import XCTest
@testable import CorckieCore

/// Hotfix 01 (H1): on the ride graph a sideways pinch zooms time and an up-down pinch stretches the values; both coexist.
final class Hotfix01TimeZoomTests: XCTestCase {
    private let full: ClosedRange<Double> = 0...1_200

    func test_thePinchAxisFollowsTheFingers() {
        XCTAssertEqual(RideGraph.pinchAxis(dx: 200, dy: 40), .time, "fingers side by side: time")
        XCTAssertEqual(RideGraph.pinchAxis(dx: 30, dy: 180), .value, "fingers one above the other: values")
        XCTAssertEqual(RideGraph.pinchAxis(dx: -150, dy: 149), .time)
    }

    func test_aSidewaysPinchNarrowsTheWindowAroundTheFingers() {
        let w = RideGraph.timeZoomed(full, full: full, scale: 4, anchor: 0.5)
        XCTAssertEqual(w.upperBound - w.lowerBound, 300, accuracy: 0.001)
        XCTAssertEqual((w.lowerBound + w.upperBound) / 2, 600, accuracy: 0.001)
        let left = RideGraph.timeZoomed(full, full: full, scale: 2, anchor: 0)
        XCTAssertEqual(left, 0...600)
        XCTAssertTrue(RideGraph.isZoomed(w, full: full))
        XCTAssertFalse(RideGraph.isZoomed(full, full: full))
    }

    func test_theWindowStaysInsideTheRideAndNeverTooShort() {
        let tight = RideGraph.timeZoomed(full, full: full, scale: 1_000, anchor: 1)
        XCTAssertEqual(tight.upperBound - tight.lowerBound, RideGraph.minWindowS, accuracy: 0.001)
        XCTAssertEqual(tight.upperBound, 1_200, accuracy: 0.001)
        XCTAssertEqual(RideGraph.timeZoomed(300...600, full: full, scale: 0.01, anchor: 0.5), full, "pinching out ends at the whole ride")
    }

    func test_dragPansAndStopsAtTheEnds() {
        let w: ClosedRange<Double> = 300...600
        XCTAssertEqual(RideGraph.timePanned(w, full: full, fraction: -0.5), 450...750, "finger left: later")
        XCTAssertEqual(RideGraph.timePanned(w, full: full, fraction: 2), 0...300, "never before the start")
        XCTAssertEqual(RideGraph.timePanned(w, full: full, fraction: -9), 900...1_200, "never after the end")
    }

    func test_valueScaleCoexistsWithTheTimeWindow() {
        // made-up speed: 10 km/h for the first half, 30 km/h for the second
        let times = (0...1_200).map(Double.init)
        let line = GraphLine(series: .speed, times: times, values: times.map { $0 < 600 ? 10 + sin($0) : 30 + sin($0) })
        let early = RideGraph.scaledRange(line, factor: 1, within: 0...300)
        XCTAssertLessThan(early.upperBound, 15, "the auto-fit follows the visible window")
        let stretched = RideGraph.scaledRange(line, factor: 4, within: 0...300)
        XCTAssertLessThan(stretched.upperBound - stretched.lowerBound, early.upperBound - early.lowerBound)
        XCTAssertTrue(stretched.contains(10), "stretched around the visible data")
        XCTAssertEqual(RideGraph.scaledRange(line, factor: 1), RideGraph.range(line, within: 0...1_200), "no window: the whole ride as before")
    }
}
