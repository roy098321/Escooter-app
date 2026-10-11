import XCTest
@testable import CorckieCore

final class T02FreezeTests: XCTestCase {
    // a9
    func test_update_noRowLost_passes_newTableAllowed() {
        let v = UpdateCheckRules.verdict(before: ["ride": 3, "place": 2], after: ["ride": 3, "place": 5, "prediction": 0])
        XCTAssertTrue(v.passed)
        XCTAssertEqual(v.newTables, ["prediction"])
        XCTAssertTrue(v.note.contains("new: prediction"))
        XCTAssertEqual(v.rowsBefore, 5)
        XCTAssertEqual(v.rowsAfter, 8)
    }

    func test_update_lostRows_fails_andNamesTheTable() {
        let v = UpdateCheckRules.verdict(before: ["ride": 3, "place": 2], after: ["ride": 2, "place": 2])
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.lost, ["ride 3 -> 2"])
        XCTAssertTrue(v.note.contains("ride 3 -> 2"))
    }

    func test_update_vanishedTable_fails() {
        let v = UpdateCheckRules.verdict(before: ["ride": 1], after: [:])
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.lost, ["ride 1 -> table missing"])
    }

    func test_update_emptyTableThatStaysEmpty_passes() {
        XCTAssertTrue(UpdateCheckRules.verdict(before: ["ride": 0], after: ["ride": 0]).passed)
    }

    // idle battery
    private let now = 1_000_000.0
    private func hourly(from startHoursAgo: Double, hours: Int, startPct: Double, perHour: Double) -> [IdleBatterySample] {
        (0...hours).map { IdleBatterySample(at: now - (startHoursAgo - Double($0)) * 3600, pct: startPct - perHour * Double($0), charging: false) }
    }

    func test_idle_needsTwelveHours() {
        let r = IdleBattery.report(hourly(from: 10, hours: 10, startPct: 80, perHour: 1), now: now)
        XCTAssertNil(r.pctPerHour)
        XCTAssertEqual(r.hoursOfData, 10, accuracy: 0.001)
        XCTAssertTrue(r.text.hasPrefix("Collecting: 10.0 of 12 h"))
    }

    func test_idle_ratePerHour_overLast24h() {
        let r = IdleBattery.report(hourly(from: 20, hours: 20, startPct: 90, perHour: 0.5), now: now)
        XCTAssertEqual(r.pctPerHour ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(r.hoursOfData, 20, accuracy: 0.001)
        XCTAssertTrue(r.text.contains("0.50 % per hour idle over the last 24 h"))
    }

    func test_idle_olderThan24h_isLeftOut() {
        let r = IdleBattery.report(hourly(from: 40, hours: 14, startPct: 100, perHour: 3), now: now)
        XCTAssertEqual(r.readings, 0)
        XCTAssertNil(r.pctPerHour)
    }

    func test_idle_chargingAndRisingAndLongGaps_areSkipped() {
        var s = hourly(from: 20, hours: 20, startPct: 90, perHour: 1)
        s[5].charging = true            // the two stretches around it are skipped
        s[12].pct = s[11].pct + 20      // a rise: that stretch is skipped
        s.remove(at: 16)                // a 2 h stretch is fine (<= 6 h)
        XCTAssertEqual(IdleBattery.report(s, now: now).hoursOfData, 17, accuracy: 0.001)
        let long = IdleBattery.report([IdleBatterySample(at: now - 20 * 3600, pct: 90, charging: false),
                                       IdleBatterySample(at: now - 10 * 3600, pct: 80, charging: false)], now: now)
        XCTAssertEqual(long.hoursOfData, 0)
    }

    func test_idle_theRideItselfIsNeverCounted() {
        let samples = [IdleBatterySample(at: now - 20 * 3600, pct: 90, charging: false),
                       IdleBatterySample(at: now - 15 * 3600, pct: 89, charging: false),
                       IdleBatterySample(at: now - 15 * 3600 + 60, pct: 89, charging: false, kind: .rideStart),
                       IdleBatterySample(at: now - 14.5 * 3600, pct: 80, charging: false, kind: .rideEnd),
                       IdleBatterySample(at: now - 13.5 * 3600, pct: 79, charging: false),
                       IdleBatterySample(at: now - 12.5 * 3600, pct: 78, charging: false)]
        let r = IdleBattery.report(samples, now: now)
        // 5 h + 1 min before the ride, 1 h + 1 h after it; the ride's own 9 % is not in the numbers
        XCTAssertEqual(r.hoursOfData, 5 + 1.0 / 60 + 2, accuracy: 0.001)
        XCTAssertNil(r.pctPerHour)
    }

    func test_idle_adding_keepsSpacing_trimsOld_andFileText() {
        var list: [IdleBatterySample] = []
        list = IdleBattery.adding(IdleBatterySample(at: now, pct: 80, charging: false), to: list)
        list = IdleBattery.adding(IdleBatterySample(at: now + 60, pct: 80, charging: false), to: list)
        XCTAssertEqual(list.count, 1)
        list = IdleBattery.adding(IdleBatterySample(at: now + 120, pct: 79, charging: false, kind: .rideStart), to: list)
        XCTAssertEqual(list.count, 2)
        list = IdleBattery.adding(IdleBatterySample(at: now + 49 * 3600, pct: 70, charging: true), to: list)
        XCTAssertEqual(list.count, 1)
        let text = IdleBattery.fileText(list, now: now + 49 * 3600)
        XCTAssertTrue(text.contains("Idle battery (P6): Collecting"))
        XCTAssertTrue(text.contains("· 70 · yes · idle"))
    }
}
