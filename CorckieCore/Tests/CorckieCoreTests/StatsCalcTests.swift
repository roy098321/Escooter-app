import XCTest
@testable import CorckieCore

/// M4-07: M34 week / month (calendar, rolling, holiday tag, same-point comparison), M35 charges and cost, M35b fuel saved.
final class StatsCalcTests: XCTestCase {
    private let off = 180

    private func ms(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        return Int64(date.timeIntervalSince1970 * 1000) - Int64(off) * 60_000
    }

    private func ride(_ start: Int64, km: Double, used: Double?, kind: String = "ride", s: Double = 900) -> StatsRide {
        StatsRide(startAt: start, utcOffsetMin: off, kind: kind, distanceM: km * 1000, totalS: s, usedPct: used)
    }

    private let prices = StatsPrices(packWh: 800, electricityIlsPerKwh: 0.64, fuelIlsByMonth: [:], fuelFallbackIls: 8.27, fuelLPer100km: 7)

    func testCalendarWeekAndMonth() {
        let now = ms(2026, 10, 7, 12)                    // Wednesday
        let w = StatsCalc.period(span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off)
        XCTAssertEqual(w.startMs, ms(2026, 10, 4))        // Sunday 00:00 local
        XCTAssertEqual(w.endMs, ms(2026, 10, 11))
        XCTAssertTrue(w.isPartial)
        XCTAssertEqual(w.label, "This week")
        let last = StatsCalc.period(span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off, back: 1)
        XCTAssertEqual(last.startMs, ms(2026, 9, 27))
        XCTAssertEqual(last.label, "Last week")
        XCTAssertFalse(last.isPartial)
        let m = StatsCalc.period(span: .month, mode: .calendar, nowMs: now, utcOffsetMin: off)
        XCTAssertEqual(m.startMs, ms(2026, 10, 1))
        XCTAssertEqual(m.endMs, ms(2026, 11, 1))
        XCTAssertEqual(m.dayCount, 31)
        let prev = StatsCalc.period(span: .month, mode: .calendar, nowMs: now, utcOffsetMin: off, back: 1)
        XCTAssertEqual(prev.startMs, ms(2026, 9, 1))
        XCTAssertEqual(prev.label, "September 2026")
    }

    func testRolling() {
        let now = ms(2026, 10, 7, 12)
        let p = StatsCalc.period(span: .week, mode: .rolling, nowMs: now, utcOffsetMin: off)
        XCTAssertEqual(p.endMs, now)
        XCTAssertEqual(p.startMs, now - 7 * 86_400_000)
        XCTAssertEqual(p.label, "Last 7 days")
        XCTAssertFalse(p.isPartial)
        let p30 = StatsCalc.period(span: .month, mode: .rolling, nowMs: now, utcOffsetMin: off, back: 1)
        XCTAssertEqual(p30.endMs, now - 30 * 86_400_000)
        XCTAssertEqual(p30.dayCount, 30)
    }

    func testTotalsChargesAndCost() {
        let now = ms(2026, 10, 7, 12)
        let p = StatsCalc.period(span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let rides = [ride(ms(2026, 10, 4, 8), km: 10, used: 12), ride(ms(2026, 10, 6, 17), km: 6, used: 8),
                     ride(ms(2026, 10, 6, 18), km: 1, used: 2, kind: "shortHop", s: 200),
                     ride(ms(2026, 9, 30, 8), km: 50, used: 60)]          // last week: not counted
        let t = StatsCalc.totals(rides, period: p, prices: prices, utcOffsetMin: off)
        XCTAssertEqual(t.rides, 2)
        XCTAssertEqual(t.shortHops, 1)
        XCTAssertEqual(t.km, 16, accuracy: 0.001)
        XCTAssertEqual(t.shortHopKm, 1, accuracy: 0.001)
        XCTAssertEqual(t.seconds, 1800, accuracy: 0.001)
        XCTAssertEqual(t.charges, 0.22, accuracy: 0.0001)                  // 22% used, short hops included
        XCTAssertEqual(t.electricityIls, 0.22 * 0.8 * 0.64, accuracy: 0.0001)
        XCTAssertEqual(StatsCalc.charges(t.charges), "~0.2")
        // bars: Sunday 10 km, Tuesday 6 km
        XCTAssertEqual(t.barsKm.count, 7)
        XCTAssertEqual(t.barsKm[0], 10, accuracy: 0.001)
        XCTAssertEqual(t.barsKm[2], 6, accuracy: 0.001)
    }

    func testFuelSavedOverTwoKmOnly() {
        let now = ms(2026, 10, 7, 12)
        let p = StatsCalc.period(span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off)
        let rides = [ride(ms(2026, 10, 4, 8), km: 10, used: 12), ride(ms(2026, 10, 6, 17), km: 6, used: 8), ride(ms(2026, 10, 6, 19), km: 1.5, used: 3)]
        let t = StatsCalc.totals(rides, period: p, prices: prices, utcOffsetMin: off)
        // 10 km: 10 x 7/100 x 8.27 - 12% x 0.008 kWh x 0.64 ; 6 km likewise ; 1.5 km is under 2 km
        let expected = (10 * 0.07 * 8.27 - 12 * 0.008 * 0.64) + (6 * 0.07 * 8.27 - 8 * 0.008 * 0.64)
        XCTAssertEqual(t.fuelSavedIls ?? 0, expected, accuracy: 0.001)
        // the month's own price wins over the fallback
        let byMonth = StatsPrices(packWh: 800, fuelIlsByMonth: ["2026-10": 9.0], fuelFallbackIls: 8.27)
        let t2 = StatsCalc.totals(rides, period: p, prices: byMonth, utcOffsetMin: off)
        XCTAssertGreaterThan(t2.fuelSavedIls ?? 0, expected)
        // no price at all: nothing claimed
        let none = StatsPrices(packWh: 800)
        XCTAssertNil(StatsCalc.totals(rides, period: p, prices: none, utcOffsetMin: off).fuelSavedIls)
    }

    func testEmptyPeriod() {
        let p = StatsCalc.period(span: .month, mode: .calendar, nowMs: ms(2026, 10, 7), utcOffsetMin: off)
        let t = StatsCalc.totals([], period: p, prices: prices, utcOffsetMin: off)
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.charges, 0)
        XCTAssertEqual(t.barsKm.count, 31)
    }

    func testHolidayTagHidesTheComparison() {
        let p = StatsCalc.period(span: .week, mode: .calendar, nowMs: ms(2026, 9, 23, 12), utcOffsetMin: off)     // week of Yom Kippur (21 Sep eve, 22 Sep)
        XCTAssertTrue(StatsCalc.holidayTagged(p, dayOffDates: ["2026-09-21"], utcOffsetMin: off))
        XCTAssertFalse(StatsCalc.holidayTagged(p, dayOffDates: ["2026-10-03"], utcOffsetMin: off))
        let rides = [ride(ms(2026, 9, 14, 8), km: 20, used: 20), ride(ms(2026, 9, 21, 8), km: 30, used: 30)]
        XCTAssertNil(StatsCalc.comparisonPct(rides, span: .week, mode: .calendar, nowMs: ms(2026, 9, 23, 12), utcOffsetMin: off, holidayTagged: true))
    }

    func testPartialPeriodComparesTheSamePoint() {
        // Wednesday noon: this week so far 30 km; last week up to the same point (Wednesday noon) 20 km, the rest of last week is not counted
        let now = ms(2026, 10, 7, 12)
        let rides = [ride(ms(2026, 10, 4, 8), km: 30, used: 20),
                     ride(ms(2026, 9, 27, 8), km: 20, used: 15),          // Sunday last week
                     ride(ms(2026, 10, 2, 8), km: 40, used: 30)]          // Friday last week: later than the same point
        let pct = StatsCalc.comparisonPct(rides, span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off, holidayTagged: false)
        XCTAssertEqual(pct ?? 0, 50, accuracy: 0.01)
        XCTAssertNil(StatsCalc.comparisonPct([ride(ms(2026, 10, 4, 8), km: 30, used: 20)], span: .week, mode: .calendar, nowMs: now, utcOffsetMin: off, holidayTagged: false))
    }

    func testTexts() {
        XCTAssertEqual(StatsCalc.money(3.456), "3.46 \u{20AA}")
        XCTAssertEqual(StatsCalc.km(12.34), "12.3 km")
        XCTAssertEqual(StatsCalc.km(123.4), "123 km")
        XCTAssertEqual(StatsCalc.duration(5_400), "1 h 30 min")
        XCTAssertEqual(StatsCalc.duration(600), "10 min")
    }
}
