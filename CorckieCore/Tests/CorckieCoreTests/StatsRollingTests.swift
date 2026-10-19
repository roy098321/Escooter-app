import XCTest
@testable import CorckieCore

/// F-16: Calendar / Rolling. Rolling = the last 7 / 30 / 365 days, the trend chip compares with the previous window of the same
/// length, and the bars are labelled with the days they really cover. Made-up dates.
final class StatsRollingTests: XCTestCase {
    private let off = 180
    private let day: Int64 = 86_400_000

    private func ms(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        return Int64(date.timeIntervalSince1970 * 1000) - Int64(off) * 60_000
    }

    private func ride(_ start: Int64, km: Double) -> StatsRide {
        StatsRide(startAt: start, utcOffsetMin: off, kind: "ride", distanceM: km * 1000, totalS: 900, usedPct: 5)
    }

    func test_rollingYear_isTheLast365Days() {
        let now = ms(2026, 10, 7, 12)
        let p = StatsCalc.period(span: .year, mode: .rolling, nowMs: now, utcOffsetMin: off)
        XCTAssertEqual(p.endMs, now)
        XCTAssertEqual(p.startMs, now - 365 * day)
        XCTAssertEqual(p.label, "Last 365 days")
        XCTAssertEqual(p.dayCount, 365)
        XCTAssertFalse(p.isPartial)
        let before = StatsCalc.period(span: .year, mode: .rolling, nowMs: now, utcOffsetMin: off, back: 1)
        XCTAssertEqual(before.endMs, now - 365 * day)
        // the calendar year is untouched
        XCTAssertEqual(StatsCalc.period(span: .year, mode: .calendar, nowMs: now, utcOffsetMin: off).label, "This year")
    }

    func test_rollingLabels_readLastNDays() {
        let now = ms(2026, 10, 7, 12)
        XCTAssertEqual(StatsCalc.period(span: .week, mode: .rolling, nowMs: now, utcOffsetMin: off).label.uppercased(), "LAST 7 DAYS")
        XCTAssertEqual(StatsCalc.period(span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off).label.uppercased(), "LAST 30 DAYS")
    }

    func test_rollingChip_comparesWithThePreviousWindowOfTheSameLength() throws {
        let now = ms(2026, 10, 7, 12)
        // this window (30 days): 30 km; the one before: 20 km => +50%
        let rides = [ride(now - 3 * day, km: 12), ride(now - 20 * day, km: 18), ride(now - 35 * day, km: 8), ride(now - 55 * day, km: 12)]
        let pct = try XCTUnwrap(StatsCalc.comparisonPct(rides, span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off, holidayTagged: false))
        XCTAssertEqual(pct, 50, accuracy: 0.001)
        // a rolling week against the 7 days before it
        let weekRides = [ride(now - 2 * day, km: 10), ride(now - 9 * day, km: 8)]
        let weekPct = try XCTUnwrap(StatsCalc.comparisonPct(weekRides, span: .week, mode: .rolling, nowMs: now, utcOffsetMin: off, holidayTagged: false))
        XCTAssertEqual(weekPct, 25, accuracy: 0.001)
        // nothing before: no chip
        XCTAssertNil(StatsCalc.comparisonPct([ride(now - day, km: 5)], span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off, holidayTagged: false))
    }

    func test_rollingTotals_countTheWindowOnly() {
        let now = ms(2026, 10, 7, 12)
        let p = StatsCalc.period(span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off)
        let prices = StatsPrices(packWh: 800, electricityIlsPerKwh: 0.64, fuelIlsByMonth: [:], fuelFallbackIls: 8.27, fuelLPer100km: 7)
        let t = StatsCalc.totals([ride(now - day, km: 6), ride(now - 30 * day + 3_600_000, km: 4), ride(now - 31 * day, km: 99)], period: p, prices: prices, utcOffsetMin: off)
        XCTAssertEqual(t.km, 10, accuracy: 0.001)
        XCTAssertEqual(t.barsKm.count, 30)
        XCTAssertEqual(t.barsKm[29], 6, accuracy: 0.001, "the newest day is the last bar")
        XCTAssertEqual(t.barsKm[0], 4, accuracy: 0.001)
    }

    func test_chartBars_calendarKeepsItsLetters() {
        let now = ms(2026, 10, 7, 12)
        let week = StatsCalc.period(span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let w = StatsCalc.chartBars(barsKm: [1, 2, 3, 4, 5, 6, 7], period: week, span: .week, mode: .calendar, utcOffsetMin: off)
        XCTAssertEqual(w.labels, ["S", "M", "T", "W", "T", "F", "S"])
        let month = StatsCalc.period(span: .month, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let m = StatsCalc.chartBars(barsKm: [Double](repeating: 1, count: month.dayCount), period: month, span: .month, mode: .calendar, utcOffsetMin: off)
        XCTAssertEqual(m.labels.count, 31)
        XCTAssertEqual(m.labels.last, "31", "the last day of the month has its label")
        let year = StatsCalc.period(span: .year, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let y = StatsCalc.chartBars(barsKm: [Double](repeating: 1, count: year.dayCount), period: year, span: .year, mode: .calendar, utcOffsetMin: off)
        XCTAssertEqual(y.values.count, 12)
        XCTAssertEqual(y.values.reduce(0, +), Double(year.dayCount), accuracy: 0.001)
        XCTAssertEqual(y.labels, ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"])
        XCTAssertEqual(y.values[0], 31, accuracy: 0.001)
        XCTAssertEqual(y.values[1], 28, accuracy: 0.001)
    }

    func test_chartBars_rollingWeekLabelsTheRealDays() {
        let now = ms(2026, 10, 7, 12)                       // Wednesday noon; the window starts last Wednesday noon
        let p = StatsCalc.period(span: .week, mode: .rolling, nowMs: now, utcOffsetMin: off)
        let b = StatsCalc.chartBars(barsKm: [Double](repeating: 1, count: 7), period: p, span: .week, mode: .rolling, utcOffsetMin: off)
        // bar midpoints: Thu 0:00, Fri, Sat, Sun, Mon, Tue, Wed 0:00 local (the midpoint of a noon-to-noon day is local midnight)
        XCTAssertEqual(b.labels.count, 7)
        XCTAssertEqual(b.labels.joined(), "TFSSMTW")
        XCTAssertEqual(Set(b.labels.prefix(3)), Set(["T", "F", "S"]))
    }

    func test_chartBars_rollingMonthAndYear() {
        let now = ms(2026, 10, 7, 12)
        let p30 = StatsCalc.period(span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off)
        let m = StatsCalc.chartBars(barsKm: [Double](repeating: 1, count: 30), period: p30, span: .month, mode: .rolling, utcOffsetMin: off)
        XCTAssertEqual(m.labels.count, 30)
        XCTAssertEqual(m.labels.last, "7", "the newest bar is today, the 7th")
        XCTAssertEqual(m.labels[22], "30", "a week earlier it was the 30th of September")
        let p365 = StatsCalc.period(span: .year, mode: .rolling, nowMs: now, utcOffsetMin: off)
        var bars = [Double](repeating: 0, count: 365)
        bars[364] = 10
        bars[0] = 5
        let y = StatsCalc.chartBars(barsKm: bars, period: p365, span: .year, mode: .rolling, utcOffsetMin: off)
        XCTAssertEqual(y.values.count, 12)
        XCTAssertEqual(y.labels.count, 12)
        XCTAssertEqual(y.values.reduce(0, +), 15, accuracy: 0.001, "nothing is lost when 365 days become 12 blocks")
        XCTAssertEqual(y.values.last ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(y.values.first ?? 0, 5, accuracy: 0.001)
    }
}
