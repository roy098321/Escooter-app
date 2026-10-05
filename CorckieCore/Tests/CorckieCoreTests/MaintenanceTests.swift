import XCTest
@testable import CorckieCore

/// M3-06: maintenance by km (status, one reminder per item, repeat after 3 days, notification rules).
final class MaintenanceTests: XCTestCase {
    static let day: Int64 = 86_400_000
    let t0: Int64 = 20_000 * 86_400_000   // midnight UTC

    private func tyres(lastOdo: Double? = 100, notified: Int64? = nil) -> MaintenanceItem {
        MaintenanceItem(id: "tyres", name: "Tyre pressure", hint: "50 PSI", intervalKm: 300, intervalDays: 14, lastDoneOdoKm: lastOdo,
                        lastDoneAt: t0, notifiedAt: notified)
    }

    func test_defaults_haveTyres50PsiAndAllThreeItems() {
        let d = Maintenance.defaults(odoKm: 10, nowMs: t0)
        XCTAssertEqual(d.map(\.id), ["tyres", "brakes", "bolts"])
        XCTAssertTrue(d[0].hint.contains("50 PSI"))
        XCTAssertEqual(d[0].intervalKm, 300)
        XCTAssertEqual(d[0].intervalDays, 14)
        XCTAssertEqual(d[0].lastDoneOdoKm, 10)
    }

    func test_status_kmLeft() {
        XCTAssertEqual(Maintenance.status(tyres(), odoKm: 250, nowMs: t0 + Self.day), .ok(kmLeft: 150))
        XCTAssertEqual(Maintenance.statusText(.ok(kmLeft: 149.6)), "150 km left")
    }

    func test_status_dueExactlyAtInterval_andOver() {
        XCTAssertEqual(Maintenance.status(tyres(), odoKm: 400, nowMs: t0), .dueKm(over: 0))
        XCTAssertEqual(Maintenance.status(tyres(), odoKm: 450, nowMs: t0), .dueKm(over: 50))
        XCTAssertFalse(Maintenance.status(tyres(), odoKm: 399, nowMs: t0).isDue)
        XCTAssertEqual(Maintenance.statusText(.dueKm(over: 0)), "Due now")
        XCTAssertEqual(Maintenance.statusText(.dueKm(over: 50)), "Due, 50 km over")
    }

    func test_status_dueByDays() {
        XCTAssertEqual(Maintenance.status(tyres(), odoKm: 110, nowMs: t0 + 13 * Self.day), .ok(kmLeft: 290))
        XCTAssertEqual(Maintenance.status(tyres(), odoKm: 110, nowMs: t0 + 16 * Self.day), .dueDays(over: 2))
    }

    func test_status_noOdometer_notStarted() {
        XCTAssertEqual(Maintenance.status(tyres(lastOdo: nil), odoKm: 50, nowMs: t0), .notStarted)
        XCTAssertEqual(Maintenance.status(tyres(), odoKm: nil, nowMs: t0), .notStarted)
    }

    func test_dayOnlyItem_ignoresOdometer() {
        let i = MaintenanceItem(id: "x", name: "X", hint: "", intervalKm: nil, intervalDays: 10, lastDoneOdoKm: nil, lastDoneAt: t0)
        XCTAssertEqual(Maintenance.status(i, odoKm: nil, nowMs: t0 + 11 * Self.day), .dueDays(over: 1))
        XCTAssertEqual(Maintenance.status(i, odoKm: nil, nowMs: t0 + Self.day), .ok(kmLeft: nil))
    }

    func test_markedDone_resetsCountAndReminder() {
        let done = Maintenance.markedDone(tyres(notified: t0), odoKm: 420, nowMs: t0 + 5 * Self.day)
        XCTAssertEqual(done.lastDoneOdoKm, 420)
        XCTAssertNil(done.notifiedAt)
        XCTAssertEqual(Maintenance.status(done, odoKm: 430, nowMs: t0 + 6 * Self.day), .ok(kmLeft: 290))
    }

    func test_toRemind_onceWhenDue_notWhenOk_againAfter3Days() {
        let now = t0 + Self.day
        XCTAssertTrue(Maintenance.toRemind([tyres()], odoKm: 200, nowMs: now).isEmpty)
        XCTAssertEqual(Maintenance.toRemind([tyres()], odoKm: 410, nowMs: now).count, 1)
        XCTAssertTrue(Maintenance.toRemind([tyres(notified: now - Self.day)], odoKm: 420, nowMs: now).isEmpty)
        XCTAssertTrue(Maintenance.toRemind([tyres(notified: now - 3 * Self.day + 1)], odoKm: 420, nowMs: now).isEmpty)
        XCTAssertEqual(Maintenance.toRemind([tyres(notified: now - 3 * Self.day)], odoKm: 420, nowMs: now).count, 1)
    }

    func test_decide_quietHours_edges() {
        func at(_ h: Int, _ m: Int = 0) -> Int64 { t0 + Int64(h * 60 + m) * 60_000 }
        XCTAssertEqual(Maintenance.decide(nowMs: at(21, 59), utcOffsetMin: 0, rideActive: false, sentToday: 0), .send)
        XCTAssertEqual(Maintenance.decide(nowMs: at(22), utcOffsetMin: 0, rideActive: false, sentToday: 0), .drop(reason: "quiet hours"))
        XCTAssertEqual(Maintenance.decide(nowMs: at(6, 59), utcOffsetMin: 0, rideActive: false, sentToday: 0), .drop(reason: "quiet hours"))
        XCTAssertEqual(Maintenance.decide(nowMs: at(7), utcOffsetMin: 0, rideActive: false, sentToday: 0), .send)
        // local time counts: 20:00 UTC in UTC+3 is 23:00
        XCTAssertEqual(Maintenance.decide(nowMs: at(20), utcOffsetMin: 180, rideActive: false, sentToday: 0), .drop(reason: "quiet hours"))
        // 01:00 UTC at UTC-5 is 20:00 the day before: fine
        XCTAssertEqual(Maintenance.decide(nowMs: at(1), utcOffsetMin: -300, rideActive: false, sentToday: 0), .send)
    }

    func test_decide_dailyLimitAndRide() {
        let noon = t0 + 12 * 3_600_000
        XCTAssertEqual(Maintenance.decide(nowMs: noon, utcOffsetMin: 0, rideActive: false, sentToday: 1), .send)
        XCTAssertEqual(Maintenance.decide(nowMs: noon, utcOffsetMin: 0, rideActive: false, sentToday: 2), .drop(reason: "daily limit"))
        XCTAssertEqual(Maintenance.decide(nowMs: noon, utcOffsetMin: 0, rideActive: true, sentToday: 0), .drop(reason: "ride active"))
    }

    func test_text_namesTheItem() {
        let t = Maintenance.text(tyres(), status: .dueKm(over: 12))
        XCTAssertEqual(t.title, "Tyre pressure due")
        XCTAssertTrue(t.body.contains("Due, 12 km over"))
    }
}
