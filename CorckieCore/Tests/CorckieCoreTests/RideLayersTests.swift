import XCTest
@testable import CorckieCore

/// M5-03: Hills and Wind layers, elevation profile with climbs, chart thinning.
final class RideLayersTests: XCTestCase {
    /// A straight ride north, 5 s apart, ~22 m per step. `alt(i)` gives the altitude of step i.
    private func line(_ n: Int, heading south: Bool = false, alt: (Int) -> Double) -> [SeriesPoint] {
        var out: [SeriesPoint] = []
        for i in 0..<n {
            let step = Double(i)
            let lat: Double = south ? 10.0 + Double(n - i) * 0.000_2 : 10.0 + step * 0.000_2
            out.append(SeriesPoint(t: step * 5, lat: lat, lon: 20.0, hAccM: 5, speedKmh: 16, batteryPct: 80 - i / 10, altM: alt(i)))
        }
        return out
    }

    private func hillAlt(_ i: Int) -> Double {
        if i < 20 { return 50 }
        if i < 40 { return 50 + Double(i - 20) * 2 }      // 2 m per 22 m = 9% up
        return 90 - Double(i - 40) * 2                      // 9% down
    }

    func testHillsHasSteepUpFlatAndSteepDown() {
        let segs = RideLayers.hills(line(60, alt: hillAlt))
        let levels = Set(segs.map(\.level))
        XCTAssertTrue(levels.contains(4), "steep up")
        XCTAssertTrue(levels.contains(2), "flat")
        XCTAssertTrue(levels.contains(0), "steep down")
        // flat comes first, then up, then down
        XCTAssertEqual(segs.first?.level, 2)
        XCTAssertEqual(segs.last?.level, 0)
        // neighbours share an end point, so the line is drawn without gaps
        for i in 1..<segs.count { XCTAssertEqual(segs[i - 1].coords.last, segs[i].coords.first) }
    }

    func testHillsNeedAltitudeAndFixes() {
        var noAlt = line(30) { _ in 50 }
        for i in noAlt.indices { noAlt[i].altM = nil }
        XCTAssertTrue(RideLayers.hills(noAlt).isEmpty)
        var noFix = line(30) { _ in 50 }
        for i in noFix.indices { noFix[i].hAccM = 80 }
        XCTAssertTrue(RideLayers.hills(noFix).isEmpty)
    }

    private func rows(windKmh: Double, from deg: Double, startMs: Int64) -> [WeatherRow] {
        let hour = (startMs / 3_600_000) * 3_600_000
        return [WeatherRow(cellKey: "c", hourAt: hour, source: "test", kind: .history, windKmh: windKmh, windFromDeg: deg, fetchedAt: 0),
                WeatherRow(cellKey: "c", hourAt: hour + 3_600_000, source: "test", kind: .history, windKmh: windKmh, windFromDeg: deg, fetchedAt: 0)]
    }

    func testWindHeadAndTail() {
        let start: Int64 = 1_790_000_000_000
        let north = line(40) { _ in 50 }
        let head = RideLayers.wind(north, rideStartMs: start, rows: rows(windKmh: 20, from: 0, startMs: start))
        XCTAssertEqual(Set(head?.map(\.level) ?? []), [4])           // wind from the north, riding north: against, 20 km/h
        let tail = RideLayers.wind(north, rideStartMs: start, rows: rows(windKmh: 20, from: 180, startMs: start))
        XCTAssertEqual(Set(tail?.map(\.level) ?? []), [0])           // from the south: with you
        let cross = RideLayers.wind(north, rideStartMs: start, rows: rows(windKmh: 20, from: 90, startMs: start))
        XCTAssertEqual(Set(cross?.map(\.level) ?? []), [2])
        let south = RideLayers.wind(line(40, heading: true) { _ in 50 }, rideStartMs: start, rows: rows(windKmh: 20, from: 0, startMs: start))
        XCTAssertEqual(Set(south?.map(\.level) ?? []), [0])          // riding south with a north wind
    }

    func testWindMissingWeatherIsNil() {
        XCTAssertNil(RideLayers.wind(line(40) { _ in 50 }, rideStartMs: 1_790_000_000_000, rows: []))
        // a row a day away is too far
        let far = rows(windKmh: 20, from: 0, startMs: 1_790_000_000_000 + 86_400_000)
        XCTAssertNil(RideLayers.wind(line(40) { _ in 50 }, rideStartMs: 1_790_000_000_000, rows: far))
    }

    func testElevationFindsTheClimbAndItsCost() {
        let points = line(60, alt: hillAlt)
        let result = RideLayers.elevation(points)
        XCTAssertEqual(result.climbs.count, 1)
        let c = result.climbs[0]
        XCTAssertEqual(c.gainM, 38, accuracy: 6)                     // 40 m real rise, smoothed
        XCTAssertGreaterThan(c.gradePct, 5)
        XCTAssertLessThan(c.gradePct, 10)
        XCTAssertNotNil(c.usedPct)
        XCTAssertTrue(c.text.hasPrefix("+"))
        XCTAssertTrue(c.text.contains("grade"))
        XCTAssertEqual(result.profile.first?.distM ?? 1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(result.profile.last?.distM ?? 0, 1_000)
    }

    func testFlatRideHasNoClimbs() {
        XCTAssertTrue(RideLayers.elevation(line(60) { i in 50 + (i % 2 == 0 ? 0.4 : -0.4) }).climbs.isEmpty)
        XCTAssertTrue(RideLayers.elevation([]).climbs.isEmpty)
    }

    func testChartSeriesKeepsEndsAndStaysSmall() {
        let many = line(1_000) { _ in 50 }
        let thin = RideLayers.chartSeries(many, max: 100)
        XCTAssertEqual(thin.count, 100)
        XCTAssertEqual(thin.first, many.first)
        XCTAssertEqual(thin.last, many.last)
        XCTAssertEqual(RideLayers.chartSeries(Array(many.prefix(10)), max: 100).count, 10)
    }

    func testLayerLegendsAndNames() {
        XCTAssertEqual(MapLayer.allCases.map(\.rawValue), ["Speed", "Hills", "Wind"])
        for layer in MapLayer.allCases { XCTAssertTrue(layer.legend.hasPrefix("Colour =")) }
    }
}
