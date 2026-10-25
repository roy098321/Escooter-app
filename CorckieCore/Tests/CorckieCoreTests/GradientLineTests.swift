import XCTest
@testable import CorckieCore

/// B59: one gradient line per unbroken run, colour stops along it by distance, no overlapping pieces.
final class GradientLineTests: XCTestCase {
    private func p(_ i: Int) -> GeoPoint { GeoPoint(lat: 10.0 + Double(i) * 0.000_3, lon: 20.0) }

    func testJoinedStretchesAreOneRun() {
        let stretches = (0..<10).map { ValueStretch(a: p($0), b: p($0 + 1), t: Double($0), value: Double($0) * 5) }
        let runs = GradientLine.runs(stretches, ramp: LayerRamps.speed(colourBlind: false))
        XCTAssertEqual(runs.count, 1, "one polyline, not ten pieces")
        XCTAssertEqual(runs[0].coords.count, 11, "every point once: nothing overlaps")
        XCTAssertEqual(runs[0].stops.first?.location, 0)
        XCTAssertEqual(runs[0].stops.last?.location, 1)
        XCTAssertEqual(runs[0].stops.count, 12)
        // locations never go backwards; the middle stop of stretch k sits at (k + 0.5) / 10
        for i in 1..<runs[0].stops.count { XCTAssertGreaterThanOrEqual(runs[0].stops[i].location, runs[0].stops[i - 1].location) }
        XCTAssertEqual(runs[0].stops[1].location, 0.05, accuracy: 0.001)
        // the colour follows the value: slow green at the start, red-ish at the end
        XCTAssertGreaterThan(runs[0].stops[1].g, runs[0].stops[1].r)
        XCTAssertGreaterThan(runs[0].stops[10].r, runs[0].stops[10].g)
    }

    func testABreakStartsANewRun() {
        var stretches = (0..<4).map { ValueStretch(a: p($0), b: p($0 + 1), t: Double($0), value: 20) }
        stretches += (10..<14).map { ValueStretch(a: p($0), b: p($0 + 1), t: Double($0), value: 20) }
        XCTAssertEqual(GradientLine.runs(stretches, ramp: LayerRamps.speed(colourBlind: false)).count, 2)
    }

    func testALongRideKeepsFewStops() {
        let stretches = (0..<2_000).map { ValueStretch(a: p($0), b: p($0 + 1), t: Double($0), value: Double($0 % 50)) }
        let runs = GradientLine.runs(stretches, ramp: LayerRamps.speed(colourBlind: false))
        XCTAssertEqual(runs.count, 1)
        XCTAssertLessThanOrEqual(runs[0].stops.count, GradientLine.maxStops + 2)
        XCTAssertEqual(runs[0].coords.count, 2_001)
    }

    func testNothingToDraw() {
        XCTAssertEqual(GradientLine.runs([], ramp: LayerRamps.speed(colourBlind: false)), [])
        let still = ValueStretch(a: p(0), b: p(0), t: 0, value: 10)
        XCTAssertEqual(GradientLine.runs([still], ramp: LayerRamps.speed(colourBlind: false)), [])
    }
}
