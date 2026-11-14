import XCTest
@testable import CorckieCore

/// I2: Measure charging speed
final class ChargeSpeedMeasureTests: XCTestCase {
    private let min: Int64 = 60_000

    func test_twoEntriesAnHourApartGiveTheRate() {
        let e = [ChargeSpeedMeasure.Entry(atMs: 0, pct: 40), ChargeSpeedMeasure.Entry(atMs: 60 * min, pct: 53.6)]
        XCTAssertEqual(ChargeSpeedMeasure.rate(e), 13.6)
    }

    func test_oneEntryOrAShortSpanGivesNothing() {
        XCTAssertNil(ChargeSpeedMeasure.rate([ChargeSpeedMeasure.Entry(atMs: 0, pct: 40)]))
        XCTAssertNil(ChargeSpeedMeasure.rate([ChargeSpeedMeasure.Entry(atMs: 0, pct: 40), ChargeSpeedMeasure.Entry(atMs: 10 * min, pct: 42)]))
    }

    func test_aFallingOrImpossibleRateGivesNothing() {
        XCTAssertNil(ChargeSpeedMeasure.rate([ChargeSpeedMeasure.Entry(atMs: 0, pct: 60), ChargeSpeedMeasure.Entry(atMs: 60 * min, pct: 55)]))
        XCTAssertNil(ChargeSpeedMeasure.rate([ChargeSpeedMeasure.Entry(atMs: 0, pct: 10), ChargeSpeedMeasure.Entry(atMs: 30 * min, pct: 90)]))
    }

    func test_entriesCanBeInAnyOrderAndSurviveEncoding() {
        let e = [ChargeSpeedMeasure.Entry(atMs: 60 * min, pct: 54), ChargeSpeedMeasure.Entry(atMs: 0, pct: 40)]
        XCTAssertEqual(ChargeSpeedMeasure.rate(e), 14.0)
        XCTAssertEqual(ChargeSpeedMeasure.decode(ChargeSpeedMeasure.encode(e)), e)
        XCTAssertEqual(ChargeSpeedMeasure.decode(nil), [])
    }

    func test_onlyRealPercentagesAreAccepted() {
        XCTAssertEqual(ChargeSpeedMeasure.validPct(" 62 "), 62)
        XCTAssertNil(ChargeSpeedMeasure.validPct("120"))
        XCTAssertNil(ChargeSpeedMeasure.validPct("abc"))
    }
}
