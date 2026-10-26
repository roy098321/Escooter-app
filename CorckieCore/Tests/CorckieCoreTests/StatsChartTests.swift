import XCTest
@testable import CorckieCore

/// Note 8: one Stats chart with a metric switch, a clear title, dashed reference lines and a readout per bar.
final class StatsChartTests: XCTestCase {
    private let off = 180

    private func ms(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return Int64(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!.timeIntervalSince1970 * 1000) - Int64(off) * 60_000
    }

    private let prices = StatsPrices(packWh: 800, electricityIlsPerKwh: 0.64, fuelIlsByMonth: [:], fuelFallbackIls: 8.27, fuelLPer100km: 7)

    private func week() -> (StatsTotals, StatsPeriod) {
        let now = ms(2026, 10, 14, 20)   // Wednesday
        let p = StatsCalc.period(span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let rides = [StatsRide(startAt: ms(2026, 10, 13, 8), utcOffsetMin: off, kind: "ride", distanceM: 9_000, totalS: 1_200, usedPct: 10),
                     StatsRide(startAt: ms(2026, 10, 13, 17), utcOffsetMin: off, kind: "ride", distanceM: 9_000, totalS: 1_500, usedPct: 10),
                     StatsRide(startAt: ms(2026, 10, 11, 9), utcOffsetMin: off, kind: "ride", distanceM: 4_000, totalS: 600, usedPct: 4)]
        return (StatsCalc.totals(rides, period: p, prices: prices, utcOffsetMin: off), p)
    }

    func testEveryMetricHasItsBarsAndTitle() {
        let (t, p) = week()
        let km = StatsChart.make(t, metric: .km, period: p, span: .week, mode: .calendar, utcOffsetMin: off)
        XCTAssertEqual(km.title, "km per day")
        XCTAssertEqual(km.bars.count, 7)
        XCTAssertEqual(km.bars[2].value, 18, accuracy: 0.001, "Tuesday 13 Oct: two rides of 9 km")
        XCTAssertEqual(km.readout(2), "13 Oct \u{00B7} 18 km")
        let rides = StatsChart.make(t, metric: .rides, period: p, span: .week, mode: .calendar, utcOffsetMin: off)
        XCTAssertEqual(rides.bars[2].value, 2)
        XCTAssertEqual(rides.readout(2), "13 Oct \u{00B7} 2 rides")
        let time = StatsChart.make(t, metric: .time, period: p, span: .week, mode: .calendar, utcOffsetMin: off)
        XCTAssertEqual(time.title, "minutes per day")
        XCTAssertEqual(time.bars[2].value, 45, accuracy: 0.001)
        let saved = StatsChart.make(t, metric: .saved, period: p, span: .week, mode: .calendar, utcOffsetMin: off)
        XCTAssertEqual(saved.title, "\u{20AA} saved per day")
        XCTAssertGreaterThan(saved.bars[2].value, 0)
        XCTAssertEqual(StatsChart.title(.km, span: .year), "km per month")
    }

    func testReferenceLinesAreRoundAndAboutAtTheTop() {
        XCTAssertEqual(StatsChart.references(max: 18), [5, 10, 15])
        XCTAssertEqual(StatsChart.references(max: 30), [10, 20, 30])
        XCTAssertEqual(StatsChart.references(max: 7, metric: .rides), [2, 4, 6])
        XCTAssertEqual(StatsChart.references(max: 0), [])
        for m in [0.7, 3.0, 47.0, 260.0] {
            let r = StatsChart.references(max: m)
            XCTAssertEqual(r.count, 3)
            XCTAssertEqual(r.last ?? 0, m, accuracy: m * 0.4, "the top line is about at the top bar")
        }
    }

    func testValueWords() {
        XCTAssertEqual(StatsChart.valueText(1, .rides), "1 ride")
        XCTAssertEqual(StatsChart.valueText(75, .time), "1 h 15 min")
        XCTAssertEqual(StatsChart.valueText(4.26, .km), "4.3 km")
        XCTAssertEqual(StatsChart.valueText(12.4, .saved), "\u{20AA}12")
    }

    func testYearIsPerMonth() {
        let now = ms(2026, 10, 14, 20)
        let p = StatsCalc.period(span: .year, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let t = StatsCalc.totals([StatsRide(startAt: ms(2026, 10, 13, 8), utcOffsetMin: off, kind: "ride", distanceM: 9_000, totalS: 1_200, usedPct: 10)],
                                 period: p, prices: prices, utcOffsetMin: off)
        let y = StatsChart.make(t, metric: .km, period: p, span: .year, mode: .calendar, utcOffsetMin: off)
        XCTAssertEqual(y.bars.count, 12)
        XCTAssertEqual(y.bars[9].value, 9, accuracy: 0.001)
        XCTAssertEqual(y.readout(9), "Oct \u{00B7} 9.0 km")
    }
}
