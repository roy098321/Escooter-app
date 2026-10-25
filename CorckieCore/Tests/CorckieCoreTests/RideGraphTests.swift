import XCTest
@testable import CorckieCore

/// Note 13: one ride graph with chips, own scales, map ↔ chart link, hills, scatter with a plain-words link, zoom.
final class RideGraphTests: XCTestCase {
    /// A made-up ride north, one reading a second: flat 100 s, a 150 s climb (slower), flat again (not a real place)
    private func ride() -> [SeriesPoint] {
        (0..<400).map { i in
            let climbing = (100..<250).contains(i)
            return SeriesPoint(t: Double(i), lat: 10.0 + Double(i) * 5 / Geo.mPerDegLat, lon: 20.0, hAccM: 5,
                               speedKmh: climbing ? 12 + Double(i % 7) : 25 + Double(i % 5), batteryPct: 80 - i / 50,
                               altM: i < 100 ? 10 : (i < 250 ? 10 + Double(i - 100) * 0.2 : 40), powerW: climbing ? 700 : 250, tempC: 30 + Double(i) / 40)
        }
    }

    private func data() -> RideLayerData {
        let p = ride()
        return RideLayerData(points: p, energy: EnergyTrack.build(p), weather: [], rideStartMs: 1_790_000_000_000)
    }

    func testSpeedIsTheOnlyDefaultChip() {
        XCTAssertEqual(GraphSeries.defaultChips, [.speed])
        let chips = RideGraph.available(data())
        XCTAssertEqual(chips.first, .speed)
        XCTAssertTrue(chips.contains(.incline) && chips.contains(.accel) && chips.contains(.batteryPerKm) && chips.contains(.power))
        XCTAssertFalse(chips.contains(.wind), "no weather: no wind chip")
    }

    func testInclineAndAcceleration() {
        let incline = RideGraph.line(.incline, data())
        XCTAssertEqual(incline.value(at: 175) ?? 0, 4, accuracy: 0.5, "0.2 m per 5 m = 4 %")
        XCTAssertEqual(incline.value(at: 330) ?? 9, 0, accuracy: 0.3)
        let accel = RideGraph.line(.accel, data())
        XCTAssertFalse(accel.isEmpty)
        XCTAssertLessThan(accel.values.min() ?? 0, 0, "decelerations are negative")
    }

    func testOwnScalesAutoFitTheVisibleStretch() {
        let speed = RideGraph.line(.speed, data())
        let all = RideGraph.range(speed, within: 0...400)
        let climb = RideGraph.range(speed, within: 120...230)
        XCTAssertLessThan(climb.upperBound, all.upperBound, "zoomed on the climb, the scale fits its slower speeds")
        XCTAssertEqual(RideGraph.normalised(all.lowerBound, in: all), 0, accuracy: 0.0001)
        XCTAssertEqual(RideGraph.normalised(all.upperBound, in: all), 1, accuracy: 0.0001)
        let zoomed = RideGraph.yZoomed(all, scale: 2)
        XCTAssertEqual(zoomed.upperBound - zoomed.lowerBound, (all.upperBound - all.lowerBound) / 2, accuracy: 0.0001)
        let flat = RideGraph.range(GraphLine(series: .battery, times: [0, 1, 2], values: [80, 80, 80]), within: 0...2)
        XCTAssertGreaterThan(flat.upperBound - flat.lowerBound, 3, "a flat line is never squashed")
        XCTAssertLessThanOrEqual(RideGraph.visible(speed, domain: 0...400, max: 100).count, 100)
    }

    func testMapAndChartAreLinked() {
        let pts = ride()
        let at = pts[200].point!
        XCTAssertEqual(RideGraph.time(near: at, points: pts), 200)
        XCTAssertNil(RideGraph.time(near: GeoPoint(lat: 11, lon: 21), points: pts), "a tap far from the route does nothing")
        XCTAssertEqual(RideGraph.position(at: 200.4, points: pts), at)
    }

    func testHillsCanBeSelected() {
        let pts = ride()
        let hills = RideGraph.hills(pts, energy: EnergyTrack.build(pts))
        XCTAssertEqual(hills.count, 1)
        XCTAssertTrue(hills[0].name?.hasPrefix("Climb 1 \u{00B7} +") == true)
        XCTAssertEqual(RideGraph.hill(at: 175, hills: hills), hills[0], "a tap on the hill selects it")
        XCTAssertNil(RideGraph.hill(at: 50, hills: hills))
        XCTAssertFalse(RideGraph.path(hills[0], points: pts).isEmpty)
    }

    func testScatterSaysHowStrongTheLinkIs() {
        let d = data()
        let pairs = RideGraph.pairs(x: RideGraph.line(.incline, d), y: RideGraph.line(.speed, d), in: nil)
        XCTAssertGreaterThan(pairs.count, 100)
        let r = RideGraph.correlation(pairs)
        XCTAssertLessThan(r ?? 0, -0.6, "steeper goes with slower")
        XCTAssertEqual(RideGraph.linkText(r, x: .incline, y: .speed), "A strong link: more incline goes with lower speed.")
        XCTAssertEqual(RideGraph.linkText(0.05, x: .temp, y: .speed), "No real link between temp and speed here.")
        XCTAssertEqual(RideGraph.linkText(nil, x: .temp, y: .speed), "Not enough readings here to say.")
        XCTAssertNil(RideGraph.correlation([(1, 1), (2, 2)]))
    }

    func testValueWords() {
        XCTAssertEqual(GraphSeries.speed.text(21.4), "21 km/h")
        XCTAssertEqual(GraphSeries.accel.text(-0.42), "\u{2212}0.4 m/s\u{00B2}")
        XCTAssertEqual(GraphSeries.incline.text(3.24), "3.2 %")
    }
}

/// Note 13 scale fix: the pinch changes the value scale around the line's data; the whole ride stays visible.
final class RideGraphScaleTests: XCTestCase {
    /// A made-up speed-change line: small wiggles within ±2 for 10 minutes, one ±30 spike
    private func line() -> GraphLine {
        let times = (0..<600).map(Double.init)
        let values = times.map { t -> Double in t == 300 ? 30 : (t == 301 ? -30 : 2 * sin(t / 7)) }
        return GraphLine(series: .accel, times: times, values: values)
    }

    func testAutoFitShowsTheSpikeSoTheWigglesLookFlat() {
        let fit = RideGraph.scaledRange(line(), factor: 1)
        XCTAssertLessThanOrEqual(fit.lowerBound, -30)
        XCTAssertGreaterThanOrEqual(fit.upperBound, 30)
        XCTAssertEqual(fit, RideGraph.range(line(), within: 0...599), "factor 1 = auto-fit")
        let wiggle = RideGraph.normalised(2, in: fit) - RideGraph.normalised(-2, in: fit)
        XCTAssertLessThan(wiggle, 0.1, "on ±30 the ±2 detail uses under a tenth of the height")
    }

    func testStretchingShowsTheDetailAroundTheData() {
        let six = RideGraph.scaledRange(line(), factor: 6)
        XCTAssertLessThan(six.upperBound - six.lowerBound, 12, "about ±5 instead of ±30")
        XCTAssertTrue(six.contains(0), "centred on the line's own data")
        let wiggle = RideGraph.normalised(2, in: six) - RideGraph.normalised(-2, in: six)
        XCTAssertGreaterThan(wiggle, 0.35, "the same full-length line now shows its detail")
        let wider = RideGraph.scaledRange(line(), factor: 0.5)
        XCTAssertGreaterThan(wider.upperBound - wider.lowerBound, 100, "it can relax wider too")
    }

    func testTheScaleIsClampedAndResets() {
        XCTAssertEqual(RideGraph.clampedScale(100), 20)
        XCTAssertEqual(RideGraph.clampedScale(0.01), 0.5)
        XCTAssertEqual(RideGraph.clampedScale(.nan), 1)
        XCTAssertEqual(RideGraph.scaledRange(line(), factor: 1), RideGraph.scaledRange(line(), factor: RideGraph.clampedScale(1)))
    }
}
