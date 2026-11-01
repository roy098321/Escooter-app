import XCTest
@testable import CorckieCore

/// Riding asks (option b): speed from the speed graph's gap, a straight level stretch of a usual route, Not here, Got it ✓.
final class RidingAsksTests: XCTestCase {
    private let o = GeoPoint(lat: 10, lon: 20)
    private func at(_ x: Double, _ y: Double) -> GeoPoint {
        GeoPoint(lat: o.lat + y / 111_320, lon: o.lon + x / (111_320 * cos(o.lat * .pi / 180)))
    }

    /// 1 km of bends (zig-zag), then 1.5 km straight and flat, then 1 km climbing 8 %
    private func route() -> AskRoutePath {
        var pts: [(point: GeoPoint, altM: Double?)] = []
        for k in 0..<50 {
            let x: Double = Double(k) * 20
            let y: Double = k % 2 == 0 ? 0 : 40
            pts.append((point: at(x, y), altM: 10))
        }
        for k in 1...75 {
            let x: Double = 1_000 + Double(k) * 20
            pts.append((point: at(x, 0), altM: 10 + Double(k % 3) * 0.3))
        }
        for k in 1...50 {
            let x: Double = 2_500 + Double(k) * 20
            pts.append((point: at(x, 0), altM: 11 + Double(k) * 1.6))
        }
        return AskRoutePath(routeId: "r1", name: "Uni", points: pts)
    }

    func testLengthFromTheSteadyRule() {
        XCTAssertEqual(RidingAsks.metres(speedKmh: 35), 800)
        XCTAssertEqual(RidingAsks.metres(speedKmh: 20), 500)
    }

    func testSpeedFromTheWidestGap() {
        let covered: [(x: Double, covered: Bool)] = stride(from: 15.0, through: 45, by: 2.5).map { (x: $0, covered: $0 >= 37.5) }
        XCTAssertEqual(RidingAsks.speed(covered: covered, wanted: 15...45), 25)
        let full: [(x: Double, covered: Bool)] = stride(from: 15.0, through: 45, by: 2.5).map { (x: $0, covered: true) }
        XCTAssertNil(RidingAsks.speed(covered: full, wanted: 15...45))
    }

    func testFindsTheStraightLevelPartAndNotHereSkipsIt() {
        let found = RidingAsks.stretches([route()], metres: 800, notHere: [])
        XCTAssertFalse(found.isEmpty)
        let first = found[0]
        XCTAssertGreaterThanOrEqual(first.fromKm, 1.0, "not on the bends")
        XCTAssertLessThan(first.fromKm, 2.5, "not on the climb")
        XCTAssertTrue(first.line.hasPrefix("Try it on the straight part of your Uni route, about"))
        let next = RidingAsks.stretches([route()], metres: 800, notHere: [first.key])
        XCTAssertFalse(next.contains { $0.key == first.key }, "Not here is remembered")
    }

    func testAskWordsAndGotIt() {
        let covered: [(x: Double, covered: Bool)] = stride(from: 15.0, through: 45, by: 2.5).map { (x: $0, covered: $0 <= 25) }
        let ask = RidingAsks.ask(covered: covered, wanted: 15...45, routes: [route()], notHere: [])
        XCTAssertEqual(ask?.line, "800 m steady at 35 km/h fills your speed graph.")
        XCTAssertNotNil(ask?.stretch)
        let s = StretchPoint(speedKmh: 34, pctPerKm: 2.6, km: 0.9, atMs: 2_000)
        XCTAssertTrue(RidingAsks.done(ask!, since: 1_000, stretches: [s]))
        XCTAssertFalse(RidingAsks.done(ask!, since: 3_000, stretches: [s]), "only stretches after the ask")
        XCTAssertEqual(RidingAsks.gotIt, "Got it \u{2713}")
    }

    func testStretchesFillTheSpeedGraphOnly() {
        let rides = (0..<6).map { RideLevelRide(id: "r\($0)", startAt: 0, distanceKm: 8, pctPerKm: 2 + Double($0) * 0.01, avgKmh: 38 + Double($0 % 3),
                                                  climbMPerKm: 5 + Double($0)) }
        let points = [StretchPoint(speedKmh: 25, pctPerKm: 1.8, km: 1, atMs: 0), StretchPoint(speedKmh: 25.5, pctPerKm: 1.82, km: 1, atMs: 0)]
        let speed = RideLevelInsights.make(.speedCost, rides: rides, stretches: points)
        XCTAssertTrue(speed.curve.contains { abs($0.x - 25) < 1.3 && $0.covered }, "two stretches at 25 km/h cover it")
        XCTAssertEqual(speed.rides, 6, "the count stays rides")
        let hills = RideLevelInsights.make(.hills, rides: rides, stretches: points)
        XCTAssertEqual(hills, RideLevelInsights.make(.hills, rides: rides), "other graphs ignore stretches")
    }
}
