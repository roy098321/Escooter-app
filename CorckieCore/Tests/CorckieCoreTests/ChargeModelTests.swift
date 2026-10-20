import XCTest
@testable import CorckieCore

/// F-31: the charge timer maths (13.6 %/h), against the mock's numbers: 18 % at 19:00.
final class ChargeModelTests: XCTestCase {
    private let day: Int64 = 86_400_000
    private var midnight: Int64 { 1_790_000_000_000 - (1_790_000_000_000 % day) }
    private var at1900: Int64 { midnight + 19 * 3_600_000 }
    private func clock(_ ms: Int64) -> String { ChargeText.clock(ms, utcOffsetMin: 0) }
    private func mock(_ target: ChargeTarget = .none) -> ChargeSession {
        ChargeSession(id: "t", startPct: 18, startMs: at1900, target: target, pctPerKm: 2.3, usualNeedPct: 20, usualName: "Work", scooterName: "G2")
    }

    func testMockTimes() {
        let s = mock()
        XCTAssertEqual(clock(ChargeModel.timeMs(toPct: 80, s)), "23:34")
        XCTAssertEqual(clock(ChargeModel.fullMs(s)), "01:02")
        XCTAssertEqual(clock(ChargeModel.notifyFullMs(s)), "01:24")
        XCTAssertEqual(ChargeText.sheetFullLine(s, utcOffsetMin: 0), "Full \u{2248} 01:02 \u{00B7} \u{201C}G2 is full\u{201D} at \u{2248} 01:24 (+5 % margin)")
        XCTAssertEqual(ChargeText.ticksLine(s, utcOffsetMin: 0), "80 % \u{2248} 23:34 \u{00B7} 100 % \u{2248} 01:02")
    }

    func testPctNowIsLinearAndClamped() {
        let s = mock()
        XCTAssertEqual(ChargeModel.pct(s, atMs: at1900), 18, accuracy: 0.001)
        XCTAssertEqual(ChargeModel.pct(s, atMs: at1900 + 3_600_000), 31.6, accuracy: 0.001)
        XCTAssertEqual(ChargeModel.pct(s, atMs: at1900 - 3_600_000), 18, accuracy: 0.001)          // clock set back: never below the start
        XCTAssertEqual(ChargeModel.pct(s, atMs: at1900 + 20 * 3_600_000), 100)
        XCTAssertEqual(ChargeModel.minutesLeft(s, atMs: at1900), 362)
        XCTAssertEqual(ChargeModel.minutesLeft(s, atMs: at1900 + 10 * 3_600_000), 0)
        XCTAssertEqual(ChargeText.duration(minutes: 125), "2 h 05 min")
    }

    func testMeasuredNightsOfTheOwner() {
        // 8 % -> 65 % took 261 min measured; the line says 57 / 13.6 h = 251 min (inside the +-1.5 %/h band)
        let s = ChargeSession(startPct: 8, startMs: 0)
        XCTAssertEqual(Double(ChargeModel.timeMs(toPct: 65, s)) / 60_000, 251.5, accuracy: 0.1)
        XCTAssertEqual(Double(ChargeModel.fullMs(ChargeSession(startPct: 63, startMs: 0))) / 60_000, 163.2, accuracy: 0.1)
    }

    func testKmTargetUsesMarginAndReserve() {
        let s = mock(.km(10))
        // 10 km x 2.3 %/km x 1.1 + 5 = 30.3 -> 31
        XCTAssertEqual(ChargeModel.pctForKm(10, pctPerKm: 2.3), 31)
        XCTAssertEqual(ChargeModel.targetPct(s), 31)
        XCTAssertEqual(clock(ChargeModel.targetMs(s)!), "19:57")
        XCTAssertEqual(ChargeText.kmLine(s, km: 10, utcOffsetMin: 0), "10 km \u{2248} 31 % \u{00B7} \u{2248} 19:57")
        XCTAssertNil(ChargeModel.pctForKm(10, pctPerKm: nil))
        XCTAssertEqual(ChargeModel.pctForKm(500, pctPerKm: 2.3), 100)
    }

    func testPctTargetAndNotificationTexts() {
        let s = mock(.pct(80))
        XCTAssertEqual(clock(ChargeModel.targetMs(s)!), "23:34")
        XCTAssertEqual(ChargeText.fullNotification(s).title, "G2 is full.")
        XCTAssertEqual(ChargeText.fullNotification(s).body, "Unplug when convenient.")
        XCTAssertEqual(ChargeText.targetNotification(mock(.km(10)), utcOffsetMin: 0)?.title, "G2 has enough for 10 km (\u{2248} 31 %).")
        XCTAssertNil(ChargeText.targetNotification(mock(), utcOffsetMin: 0))
    }

    func testNotificationPlanOnlyFuture() {
        let s = mock(.pct(80))
        let all = ChargeNotifications.plan(s, nowMs: at1900, utcOffsetMin: 0)
        XCTAssertEqual(all.map(\.id), ["charge.full", "charge.target"])
        XCTAssertEqual(clock(all[0].atMs), "01:24")
        let late = ChargeNotifications.plan(s, nowMs: at1900 + 5 * 3_600_000, utcOffsetMin: 0)   // 00:00: the 80 % note has passed
        XCTAssertEqual(late.map(\.id), ["charge.full"])
        XCTAssertTrue(ChargeNotifications.plan(s, nowMs: at1900 + 8 * 3_600_000, utcOffsetMin: 0).isEmpty)
    }

    func testReadyBy() {
        let ready = ChargeModel.nextOccurrence(minuteOfDay: 7 * 60 + 30, afterMs: at1900, utcOffsetMin: 0)
        XCTAssertEqual(clock(ready), "07:30")
        XCTAssertEqual(ready, midnight + day + (7 * 60 + 30) * 60_000)
        let s = mock(.readyBy(atMs: ready))
        XCTAssertEqual(ChargeText.readyByLine(s, atMs: ready, utcOffsetMin: 0), "\u{2248} 100 % by then, enough for Work and back")
        // 22:00 the same evening: 18 + 3 x 13.6 = 58.8 -> ~59 %; the usual need 20 x 1.1 + 5 = 27 -> enough
        let t22 = midnight + 22 * 3_600_000
        XCTAssertEqual(ChargeText.readyByLine(s, atMs: t22, utcOffsetMin: 0), "\u{2248} 59 % by 22:00, enough for Work and back")
        var tight = s
        tight.usualNeedPct = 50      // 50 x 1.1 + 5 = 60 > 58.8
        XCTAssertEqual(ChargeText.readyByLine(tight, atMs: t22, utcOffsetMin: 0), "\u{2248} 59 % by 22:00, not enough for Work and back")
        // full by then: the ready-by note is skipped, the full note stays
        XCTAssertEqual(ChargeNotifications.plan(s, nowMs: at1900, utcOffsetMin: 0).map(\.id), ["charge.full"])
        // a clock time already past today means tomorrow
        XCTAssertEqual(ChargeModel.nextOccurrence(minuteOfDay: 19 * 60, afterMs: at1900, utcOffsetMin: 0), at1900 + day)
        // local offset +3 h: 07:30 local is 04:30 UTC
        XCTAssertEqual(ChargeText.clock(ChargeModel.nextOccurrence(minuteOfDay: 450, afterMs: at1900, utcOffsetMin: 180), utcOffsetMin: 180), "07:30")
    }

    func testLogEntryMeasuredVersusEstimated() {
        let s = mock()
        let est = ChargeLogEntry.finish(s, atMs: at1900 + 3_600_000, realPct: nil)
        XCTAssertFalse(est.measured)
        XCTAssertEqual(est.endPct, 31.6, accuracy: 0.001)
        let real = ChargeLogEntry.finish(s, atMs: at1900 + 3_600_000, realPct: 35)
        XCTAssertTrue(real.measured)
        XCTAssertEqual(real.gainedPct, 17)
    }

    func testChartSegmentsRowsAndDetails() {
        let r = [ChargeReading(ms: 0, pct: 80), ChargeReading(ms: 3_600_000, pct: 75), ChargeReading(ms: 20 * 3_600_000, pct: 33)]
        let seg = ChargeLogChart.segments(r)
        XCTAssertEqual(seg.map(\.dashed), [false, true])
        let m = ChargeLogEntry(id: "m", startMs: 100 * 3_600_000, endMs: 102 * 3_600_000 + 19 * 60_000, startPct: 33, endPct: 65, measured: true)
        let e = ChargeLogEntry(id: "e", startMs: 130 * 3_600_000, endMs: 135 * 3_600_000, startPct: 20, endPct: 88, measured: false)
        let d = DetectedCharge(id: "d", afterRideId: "a", beforeRideId: "b", fromPct: 40, toPct: 98, windowStartAt: 10 * 3_600_000, windowEndAt: 24 * 3_600_000,
                               startedByShutdownFlag: false, inferredWhileAway: false, isSimulated: false)
        let overlapped = DetectedCharge(id: "o", afterRideId: "a", beforeRideId: "b", fromPct: 30, toPct: 66, windowStartAt: 99 * 3_600_000, windowEndAt: 104 * 3_600_000,
                                        startedByShutdownFlag: false, inferredWhileAway: false, isSimulated: false)
        let rows = ChargeLogChart.rows(entries: [m, e], detected: [d, overlapped])
        XCTAssertEqual(rows.map(\.id), ["e", "m", "d"])
        XCTAssertEqual(rows.map(\.solid), [false, true, true])
        XCTAssertEqual(ChargeLogChart.detail(rows[0]), "+68 % \u{00B7} \u{2248} 5 h 00")
        XCTAssertEqual(ChargeLogChart.detail(rows[1]), "+32 % \u{00B7} 2 h 19")
        XCTAssertEqual(ChargeLogChart.detail(rows[2]), "+58 % \u{00B7} overnight")
    }
}
