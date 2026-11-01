import XCTest
@testable import CorckieCore

/// R2: a mark where the battery first dropped below each 10 %.
final class BatteryMarksTests: XCTestCase {
    private func ride(_ battery: [Int]) -> [SeriesPoint] {
        battery.enumerated().map { i, b in
            SeriesPoint(t: Double(i), lat: 10.0 + Double(i) * 0.000_1, lon: 20.0, hAccM: 5, speedKmh: 20, batteryPct: b)
        }
    }

    func testAFullRideMarksEachTen() {
        let marks = BatteryMarks.marks(ride(Array((64...100).reversed())))
        XCTAssertEqual(marks.map(\.level), [90, 80, 70])
        XCTAssertEqual(marks.map(\.text), ["90%", "80%", "70%"])
        // the 90 mark sits where it first read 89
        XCTAssertEqual(marks[0].point.lat, 10.0 + 11 * 0.000_1, accuracy: 1e-9)
    }

    func testAFlickerGivesOneMark() {
        XCTAssertEqual(BatteryMarks.marks(ride([95, 92, 90, 89, 90, 89, 90, 89, 88])).map(\.level), [90])
    }

    func testNoMarkForTheStartingLevel() {
        XCTAssertEqual(BatteryMarks.marks(ride([90, 89, 85])).map(\.level), [])
        XCTAssertEqual(BatteryMarks.marks(ride([100, 99, 95])).map(\.level), [])
    }

    func testAJumpPastTwoLevelsMarksBoth() {
        XCTAssertEqual(BatteryMarks.marks(ride([82, 81, 69])).map(\.level), [80, 70])
    }

    func testNoBatteryNoMarks() {
        XCTAssertEqual(BatteryMarks.marks([SeriesPoint(t: 0, lat: 1, lon: 1, hAccM: 5)]), [])
    }
}
