import CorckieCore
import XCTest

/// N6-2 guard tests: the Battery log line uses the smoothed level (no sag spikes), the average is time-weighted, charges closer
/// than 15 min are one charge.
final class BatteryLogTests: XCTestCase {
    /// A made-up 10-minute ride: the raw % sags to 92 under load and comes back to 95; the smoothed line never dips like that.
    func test_N6_2_rideLineIsTheSmoothedLevel_noSagSpike() {
        var pts: [SeriesPoint] = []
        for i in 0..<120 {   // 5 s samples
            let loaded = i >= 40 && i < 60
            let raw = loaded ? 92 : (i < 40 ? 99 : 95)
            pts.append(SeriesPoint(t: 1_000 + Double(i) * 5, speedKmh: 20, batteryPct: raw, powerW: loaded ? 600 : 150))
        }
        let line = BatteryLog.smoothedRide(pts, whPerPct: 7)
        XCTAssertFalse(line.isEmpty)
        XCTAssertLessThanOrEqual(line.count, 12, "about one point a minute")
        XCTAssertGreaterThan(line.map(\.pct).min() ?? 0, 92.5, "the load sag (raw 92) does not show")
        for i in 1..<line.count { XCTAssertLessThanOrEqual(line[i].pct, line[i - 1].pct + 0.01, "a ride only drains") }
    }

    func test_N6_2_averageIsTimeWeighted_andSkipsGaps() {
        let h: Int64 = 3_600_000
        // 1 h at 100 then a 3 h drop to 40: (100 for 1 h + mean 70 for 3 h) / 4 h = 77.5
        let r = [ChargeReading(ms: 0, pct: 100), ChargeReading(ms: h, pct: 100), ChargeReading(ms: 4 * h, pct: 40)]
        XCTAssertEqual(BatteryLog.average(r)!, 77.5, accuracy: 0.01)
        // a piece across a 2-day gap does not count
        let gap = r + [ChargeReading(ms: 52 * h, pct: 0)]
        XCTAssertEqual(BatteryLog.average(gap)!, 77.5, accuracy: 0.01)
        XCTAssertEqual(BatteryLog.averageText(80.4), "avg 80%")
    }

    func test_N6_2_chargesUnder15MinApartMerge() {
        let m: Int64 = 60_000
        let a = ChargeRow(id: "a", startMs: 0, endMs: 60 * m, startPct: 30, endPct: 60, source: .measured)
        let b = ChargeRow(id: "b", startMs: 70 * m, endMs: 120 * m, startPct: 60, endPct: 90, source: .measured)   // 10 min later
        let c = ChargeRow(id: "c", startMs: 300 * m, endMs: 330 * m, startPct: 50, endPct: 70, source: .seen)      // hours later
        let merged = BatteryLog.merged([c, b, a])
        XCTAssertEqual(merged.map(\.id), ["a", "c"])
        XCTAssertEqual(merged[0].endMs, 120 * m)
        XCTAssertEqual(merged[0].endPct, 90)
        XCTAssertEqual(BatteryLog.chargeCount([a, b, c], fromMs: 0, toMs: 400 * m), 2)
    }

    func test_N6_2_headlineAndRanges() {
        XCTAssertEqual(BatteryLog.headline(charges: 6, rides: 12, range: .week), "now \u{00B7} 6 charges \u{00B7} 12 rides")
        XCTAssertEqual(BatteryLog.headline(charges: 1, rides: 3, range: .day), "now \u{00B7} 1 charge \u{00B7} 3 rides today")
        let day: Int64 = 86_400_000
        XCTAssertEqual(BatteryLog.dayRange(dayStartMs: 10 * day, nowMs: 10 * day + 5_000).fromMs, 9 * day + 5_000, "today = last 24 h")
        XCTAssertEqual(BatteryLog.dayRange(dayStartMs: 8 * day, nowMs: 10 * day).toMs, 9 * day)
        XCTAssertEqual(BatteryLog.weekRange(todayStartMs: 10 * day, nowMs: 10 * day + 1).fromMs, 4 * day)
    }

    func test_N6_2_windowStartsAtTheEdge() {
        let h: Int64 = 3_600_000
        let w = BatteryLog.window([ChargeReading(ms: 0, pct: 100), ChargeReading(ms: 2 * h, pct: 50)], fromMs: h, toMs: 3 * h)
        XCTAssertEqual(w.first?.ms, h)
        XCTAssertEqual(w.first?.pct ?? 0, 75, accuracy: 0.01)
    }
}
