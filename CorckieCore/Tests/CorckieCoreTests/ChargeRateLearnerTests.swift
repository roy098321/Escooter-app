import XCTest
@testable import CorckieCore

/// Batch 102: the charging speed learned from Plug in (start % + time, the next real reading).
final class ChargeRateLearnerTests: XCTestCase {
    private let h: Int64 = 3_600_000

    private func entry(_ id: String, from: Double, to: Double, hours: Double, measured: Bool = true) -> ChargeLogEntry {
        ChargeLogEntry(id: id, startMs: 0, endMs: Int64(hours * Double(h)), startPct: from, endPct: to, measured: measured)
    }

    func testThreeGoodChargesTeachTheSpeed() {
        let log = [entry("a", from: 30, to: 70, hours: 2.5),          // 16 %/h
                   entry("b", from: 40, to: 80, hours: 2.5),          // 16 %/h
                   entry("c", from: 20, to: 60, hours: 4),            // 10 %/h (idle time after the charger stopped)
                   entry("d", from: 50, to: 100, hours: 3),           // full: left out
                   entry("e", from: 50, to: 80, hours: 2, measured: false)]
        let l = ChargeRateLearner.learn(log)
        XCTAssertEqual(l?.charges, 3)
        XCTAssertEqual(l?.ratePctPerHour ?? 0, 16, accuracy: 0.05, "the faster half: windows only show a lower bound")
        XCTAssertNil(ChargeRateLearner.learn(Array(log.prefix(2))), "two charges are not enough")
    }

    func testTheSessionUsesTheLearnedSpeed() {
        let s = ChargeSession(startPct: 60, startMs: 0, ratePctPerHour: 16, rateFromCharges: 3)
        XCTAssertEqual(ChargeModel.fullMs(s), Int64(2.5 * Double(h)))
        XCTAssertTrue(PlugIn.why(s, .battery(100), utcOffsetMin: 0).contains("16 % an hour (learned from your last 3 charges)"))
        XCTAssertEqual(ChargeModel.rate(ChargeSession(startPct: 60, startMs: 0)), 13.6)
    }

    func testAnUnpluggedEntryGetsItsRealEnd() {
        let e = entry("u", from: 30, to: 62, hours: 2, measured: false).withRealEnd(64)
        XCTAssertTrue(e.measured)
        XCTAssertEqual(e.endPct, 64)
        XCTAssertEqual(e.endMs, 2 * h)
    }
}
