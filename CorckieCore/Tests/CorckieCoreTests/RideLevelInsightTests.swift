import XCTest
@testable import CorckieCore

/// Insights plan (batch 102): whole-ride %/km fits, real progress, partial graph with a band, one-line hints.
final class RideLevelInsightTests: XCTestCase {
    /// Made-up rides: %/km = 2.0 + 0.04 × (speed − 25) with a small wobble
    private func speedRides(_ speeds: [Double]) -> [RideLevelRide] {
        var out: [RideLevelRide] = []
        for (i, v) in speeds.enumerated() {
            let wobble: Double = (i % 2 == 0 ? 0.03 : -0.03)
            let y: Double = 2.0 + 0.04 * (v - 25) + wobble
            out.append(RideLevelRide(id: "r\(i)", startAt: Int64(i) * 86_400_000, distanceKm: 8, pctPerKm: y, avgKmh: v))
        }
        return out
    }

    func testTheFit() throws {
        let fit = try XCTUnwrap(LinearFit.make([(x: 1, y: 2), (x: 2, y: 4), (x: 3, y: 6.1), (x: 4, y: 7.9)]))
        XCTAssertEqual(fit.slope, 1.97, accuracy: 0.05)
        XCTAssertGreaterThan(fit.r, 0.99)
        XCTAssertTrue(fit.isSignificant)
        XCTAssertNil(LinearFit.make([(x: 1, y: 2), (x: 1, y: 3), (x: 1, y: 4)]), "no spread of x, no line")
    }

    func testRidesNeededMatchesTheFeasibilityMaths() {
        // feasibility 26 Oct: r 0.58 → ~21 rides, r 0.78 → ~11 rides
        XCTAssertEqual(Double(RidesNeeded.forCorrelation(0.58) ?? 0), 21, accuracy: 2)
        XCTAssertEqual(Double(RidesNeeded.forCorrelation(0.78) ?? 0), 11, accuracy: 2)
        XCTAssertNil(RidesNeeded.forCorrelation(0.05))
        XCTAssertEqual(RidesNeeded.moreText(7), "About 7 more rides")
        XCTAssertEqual(RidesNeeded.moreText(23), "About 25 more rides")
        XCTAssertEqual(RidesNeeded.moreText(1), "About 1 more ride")
    }

    func testFewRidesSayHowManyMore() {
        let i = RideLevelInsights.make(.speedCost, rides: speedRides([30, 35]))
        XCTAssertEqual(i.stage, .learning)
        XCTAssertEqual(i.progressLine, "About 2 more rides for a first read")
        XCTAssertTrue(i.curve.isEmpty)
        XCTAssertNotNil(i.hint)
    }

    func testPartialGraphIsSolidWhereThereIsDataAndABandElsewhere() {
        let i = RideLevelInsights.make(.speedCost, rides: speedRides([34, 35, 36, 35, 34, 36, 40, 41, 40, 39, 35, 40]))
        XCTAssertNotEqual(i.stage, .learning)
        XCTAssertTrue(i.range?.contains("% per km") == true || i.range == RideLevelInsights.noClearCost)
        let covered = i.curve.filter(\.covered).map(\.x)
        XCTAssertTrue(covered.contains { abs($0 - 35) < 1.3 })
        let thin = i.curve.first { abs($0.x - 20) < 1.3 }
        XCTAssertEqual(thin?.covered, false, "no rides at 20 km/h: band, not a line")
        XCTAssertGreaterThan((thin?.hi ?? 0) - (thin?.lo ?? 0), 0)
        // nothing below ~33 km/h: the hint asks for the slower part
        XCTAssertEqual(i.hint, "Ride steady at 15\u{2013}33 km/h to fill this in.")
    }

    func testTemperatureWaitsForColderDays() {
        let rides = (0..<10).map { RideLevelRide(id: "t\($0)", startAt: 0, distanceKm: 8, pctPerKm: 2, airTempC: 28 + Double($0 % 4)) }
        let i = RideLevelInsights.make(.temperature, rides: rides)
        XCTAssertEqual(i.progressLine, "Waiting for colder days")
        XCTAssertEqual(i.hint, "Colder days will fill this in.")
    }

    func testOrder() {
        XCTAssertLessThan(RideLevelInsights.rank("hills"), RideLevelInsights.rank("speedCost"))
        XCTAssertLessThan(RideLevelInsights.rank("creep"), RideLevelInsights.rank("temperature"))
        XCTAssertLessThan(RideLevelInsights.rank("wind"), RideLevelInsights.rank("departure"))
    }
}
