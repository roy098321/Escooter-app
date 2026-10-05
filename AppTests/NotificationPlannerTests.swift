import CorckieCore
import Foundation
import GRDB
import XCTest

/// M4-04: the budget counters and the weekly text on the real schema.
final class NotificationPlannerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-notify-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1")
    }

    func test_weeklyTextFromTheSimulatedWeek_andLoggedOnce() throws {
        let db = try open()
        let r = try InsightSeed.windyWeek(db, rides: 24)
        let off = FactorSeed.utcOffsetMin
        guard let plan = NotificationPlanner.weekly(db, nowMs: r.nowMs, utcOffsetMin: off) else { return XCTFail("no weekly text") }
        XCTAssertTrue(plan.body.hasPrefix("Last week:"), plan.body)
        XCTAssertGreaterThan(plan.fireMs, r.nowMs)
        // scheduled: it keeps its place that day, and is logged as sent once after its time
        NotificationPlanner.markWeeklyScheduled(db, fireMs: plan.fireMs)
        XCTAssertEqual(NotificationPlanner.sentToday(db, nowMs: plan.fireMs, utcOffsetMin: off), 0)
        NotificationPlanner.logDeliveredWeekly(db, nowMs: plan.fireMs + 60_000)
        NotificationPlanner.logDeliveredWeekly(db, nowMs: plan.fireMs + 120_000)
        XCTAssertEqual(try MessageLogQueries(db).entries(type: "weekly_summary").count, 1)
        XCTAssertEqual(NotificationPlanner.sentToday(db, nowMs: plan.fireMs + 60_000, utcOffsetMin: off), 1)
    }

    func test_noWeeklyWithoutRides() throws {
        let db = try open()
        XCTAssertNil(NotificationPlanner.weekly(db, nowMs: 1_790_000_000_000, utcOffsetMin: 180))
    }

    func test_weeklyKeepsItsPlaceTheSameDay() throws {
        let db = try open()
        let fire = NotificationBudget.nextWeeklyMs(nowMs: 1_790_000_000_000, utcOffsetMin: 180)
        NotificationPlanner.markWeeklyScheduled(db, fireMs: fire)
        XCTAssertTrue(NotificationPlanner.weeklyDueToday(db, nowMs: fire - 3_600_000, utcOffsetMin: 180))
        XCTAssertFalse(NotificationPlanner.weeklyDueToday(db, nowMs: fire - 3 * 86_400_000, utcOffsetMin: 180))
        XCTAssertFalse(NotificationPlanner.weeklyDueToday(db, nowMs: fire + 1000, utcOffsetMin: 180))
    }

    func test_windOnceADay_andDropsAreLogged() throws {
        let db = try open()
        let now: Int64 = 1_790_000_000_000
        XCTAssertFalse(NotificationPlanner.windSentToday(db, nowMs: now, utcOffsetMin: 180))
        NotificationPlanner.logSent(db, .windPickingUp, nowMs: now)
        XCTAssertTrue(NotificationPlanner.windSentToday(db, nowMs: now + 1000, utcOffsetMin: 180))
        XCTAssertFalse(NotificationPlanner.windSentToday(db, nowMs: now + 2 * 86_400_000, utcOffsetMin: 180))
        NotificationPlanner.logDropped(db, .maintenance, reason: "quiet hours", nowMs: now)
        let rows = try MessageLogQueries(db).entries(type: "maintenance")
        XCTAssertEqual(rows.first?.droppedReason, "quiet hours")
        XCTAssertNil(rows.first?.sentAt)
        XCTAssertNil(NotificationPlanner.wind(db, nowMs: now, utcOffsetMin: 180))   // no routes: nothing to say
    }
}
