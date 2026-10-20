import XCTest
@testable import CorckieCore

final class InfoFormulaTests: XCTestCase {
    func test_B32_moneyPartsSumToTheShownTotal() {
        let c = InfoFormula.money(grossIls: 145.7449, electricityIls: 0.2651, km: 126, lPer100: 14, rate: 0.64, charges: 0.5)
        XCTAssertEqual(c.formula.map(\.text), ["145.74 \u{20AA}", "0.27 \u{20AA}", "145.47 \u{20AA}"])
        XCTAssertTrue(c.partsSumToTotal)
        XCTAssertEqual(InfoFormula.shownSaved(gross: 145.7449, electricity: 0.2651), 145.47)
    }

    func test_B32_everyFormulaSheetIsConsistent() {
        var s = OverallStats()
        s.hasFuelPrice = true; s.fuelSavedIls = 1234.565; s.electricityIls = 78.905; s.totalKm = 1603.4; s.carLPer100km = 7
        XCTAssertTrue(InfoFormula.overall(s).partsSumToTotal)
        XCTAssertTrue(InfoFormula.perKm(s).partsSumToTotal)
        s.totalKm = 57.34
        XCTAssertTrue(InfoFormula.perKm(s).partsSumToTotal)
    }

    func test_inconsistentRowsAreCaught() {
        let rows = [InfoFormulaRow("a", 145.74, role: .start), InfoFormulaRow("b", 0.27, role: .minus), InfoFormulaRow("c", 145.46, role: .result)]
        XCTAssertFalse(InfoFormula.consistent(rows))
    }

    func test_colourStoredValue() {
        XCTAssertEqual(ScooterColour.from(stored: nil), .sand)
        XCTAssertEqual(ScooterColour.from(stored: "zzz"), .sand)
        for c in ScooterColour.allCases { XCTAssertEqual(ScooterColour.from(stored: c.rawValue), c) }
        XCTAssertEqual(ScooterColour.allCases.count, 6)
    }

    /// B33: rides in 4 different weeks, one riding day each, give 4 bars (the gap week is 0), not one
    func test_B33_weekBucketsAcrossFourWeeks() {
        let day = OutsideTime.dayMs
        let now: Int64 = 1_790_000_000_000
        let cur = InsightWeek.start(ms: now, utcOffsetMin: 0)
        let rides: [(startMs: Int64, km: Double)] = [(cur - 1 * 7 * day + day, 5), (cur - 2 * 7 * day + 2 * day, 7), (cur - 2 * 7 * day + 2 * day + 3_600_000, 1),
                                                     (cur - 4 * 7 * day + 3 * day, 9), (cur + day, 99)]
        let bars = WeekBars.make(rides: rides, nowMs: now, utcOffsetMin: 0)
        XCTAssertEqual(bars.map(\.km), [9, 0, 8, 5])
        XCTAssertEqual(bars.map(\.rides), [1, 0, 2, 1])
        XCTAssertTrue(WeekBars.make(rides: [], nowMs: now, utcOffsetMin: 0).isEmpty)
    }
}
