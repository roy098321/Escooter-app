import XCTest
@testable import CorckieCore

/// F-31b: Plug in after every ride: when the pill shows, − / + steps, the alert time with its margin, the "estimated" explanation.
final class PlugInTests: XCTestCase {
    private let end: Int64 = 1_790_000_000_000
    private let hour: Int64 = 3_600_000

    func testShowsAfterEveryRideForTwoHours() {
        XCTAssertTrue(PlugIn.shows(rideEndMs: end, nowMs: end + 60_000, riding: false, charging: false, connected: false, lastConnectMs: end - 20 * 60_000))
        XCTAssertTrue(PlugIn.shows(rideEndMs: end, nowMs: end + 2 * hour, riding: false, charging: false, connected: false, lastConnectMs: nil))
        XCTAssertFalse(PlugIn.shows(rideEndMs: end, nowMs: end + 2 * hour + 1, riding: false, charging: false, connected: false, lastConnectMs: nil), "gone after 2 h")
        XCTAssertFalse(PlugIn.shows(rideEndMs: end, nowMs: end + 60_000, riding: true, charging: false, connected: false, lastConnectMs: nil), "never during a ride")
        XCTAssertFalse(PlugIn.shows(rideEndMs: end, nowMs: end + 60_000, riding: false, charging: true, connected: false, lastConnectMs: nil), "charging: the charge line instead")
        XCTAssertFalse(PlugIn.shows(rideEndMs: end, nowMs: end + 60_000, riding: false, charging: false, connected: true, lastConnectMs: nil))
        XCTAssertFalse(PlugIn.shows(rideEndMs: end, nowMs: end + hour, riding: false, charging: false, connected: false, lastConnectMs: end + 30 * 60_000),
                       "gone at the next connect")
        XCTAssertFalse(PlugIn.shows(rideEndMs: nil, nowMs: end, riding: false, charging: false, connected: false, lastConnectMs: nil))
    }

    func testStepsAndTyping() {
        XCTAssertEqual(PlugAlert.default, .battery(100))
        XCTAssertEqual(PlugAlert.default.pillText, "100%")
        XCTAssertEqual(PlugAlert.range(15).pillText, "15 km")
        XCTAssertEqual(PlugIn.stepped(.battery(100), by: -1), .battery(95))
        XCTAssertEqual(PlugIn.stepped(.battery(100), by: 1), .battery(100), "never above 100")
        XCTAssertEqual(PlugIn.stepped(.battery(5), by: -1), .battery(5))
        XCTAssertEqual(PlugIn.stepped(.range(15), by: 1), .range(16))
        XCTAssertEqual(PlugIn.typed("72", for: .battery(100)), .battery(72))
        XCTAssertEqual(PlugIn.typed("500", for: .range(15)), .range(150))
        XCTAssertNil(PlugIn.typed("abc", for: .range(15)))
        XCTAssertEqual(PlugIn.switched(.battery(80), toRange: true, lastKm: 12), .range(12))
        XCTAssertEqual(PlugIn.switched(.range(12), toRange: false, lastPct: 80), .battery(80))
    }

    func testAlertTimeIncludesTheMargin() {
        // plugged in at 18 %: 100 % + 5 % margin = 87 points at 13.6 %/h
        let s = ChargeSession(startPct: 18, startMs: end, pctPerKm: 2.0, reservePct: 10, scooterName: "Test")
        let full = PlugIn.alertMs(s, .battery(100))
        XCTAssertEqual(full, ChargeModel.notifyFullMs(s))
        XCTAssertEqual(Double((full ?? 0) - end) / Double(hour), 87 / 13.6, accuracy: 0.001)
        XCTAssertEqual(PlugIn.alertMs(s, .battery(80)), ChargeModel.timeMs(toPct: 80, s))
        // 15 km at 2 %/km +10 % + 10 % reserve = 43 %
        XCTAssertEqual(PlugIn.alertMs(s, .range(15)), ChargeModel.timeMs(toPct: 43, s))
        XCTAssertEqual(PlugIn.target(.battery(100)), ChargeTarget.none, "100 % is the full notification itself")
        XCTAssertEqual(PlugIn.target(.battery(80)), .pct(80))
        XCTAssertEqual(PlugIn.target(.range(15)), .km(15))
        // the notifications fire at the same times the sheet shows
        let plan = ChargeNotifications.plan(ChargeSession(startPct: 18, startMs: end, target: PlugIn.target(.range(15)), pctPerKm: 2.0,
                                                          reservePct: 10, scooterName: "Test"), nowMs: end, utcOffsetMin: 0)
        XCTAssertTrue(plan.contains { $0.atMs == PlugIn.alertMs(s, .range(15)) })
    }

    func testEstimatedSaysWhy() {
        let s = ChargeSession(startPct: 18, startMs: end, pctPerKm: 2.0, reservePct: 10, scooterName: "Test")
        let full = PlugIn.why(s, .battery(100), utcOffsetMin: 0)
        XCTAssertTrue(full.contains("13.6 % an hour"))
        XCTAssertTrue(full.contains("Started at 18%"))
        XCTAssertTrue(full.contains("5 % longer"))
        XCTAssertTrue(full.contains("next connect"))
        XCTAssertTrue(PlugIn.why(s, .range(15), utcOffsetMin: 0).contains("2 % per km"))
        let unknown = ChargeSession(startPct: 18, startMs: end, scooterName: "Test")
        XCTAssertNil(PlugIn.alertClock(unknown, .range(15), utcOffsetMin: 0), "no %/km yet: no clock")
        XCTAssertTrue(PlugIn.why(unknown, .range(15), utcOffsetMin: 0).contains("Needs a few rides first"))
        XCTAssertNotNil(PlugIn.chargeLineAlert(s, .battery(100), utcOffsetMin: 0))
    }
}
