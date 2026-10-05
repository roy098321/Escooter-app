import XCTest
@testable import CorckieCore

/// M4-04: the shared notification budget (2 a day, quiet hours, never during a ride, weekly Sunday 07:30, wind once a day).
final class NotificationBudgetTests: XCTestCase {
    private let off = 180   // UTC+3

    /// Local time -> epoch ms
    private func ms(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        return Int64(date.timeIntervalSince1970 * 1000) - Int64(off) * 60_000
    }

    func testNeverDuringARide() {
        for kind in BudgetedMessage.allCases {
            XCTAssertEqual(NotificationBudget.decide(kind, nowMs: ms(2026, 10, 6, 12), utcOffsetMin: off, rideActive: true, sentToday: 0),
                           .drop(reason: "ride active"))
        }
    }

    func testQuietHoursDropMaintenanceAndWindButNotTheWeekly() {
        for hour in [22, 23, 0, 3, 6] {
            let t = ms(2026, 10, 6, hour)
            XCTAssertEqual(NotificationBudget.decide(.maintenance, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 0), .drop(reason: "quiet hours"))
            XCTAssertEqual(NotificationBudget.decide(.windPickingUp, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 0), .drop(reason: "quiet hours"))
        }
        XCTAssertEqual(NotificationBudget.decide(.maintenance, nowMs: ms(2026, 10, 6, 7), utcOffsetMin: off, rideActive: false, sentToday: 0), .send)
        XCTAssertEqual(NotificationBudget.decide(.maintenance, nowMs: ms(2026, 10, 6, 21, 59), utcOffsetMin: off, rideActive: false, sentToday: 0), .send)
        XCTAssertEqual(NotificationBudget.decide(.weeklySummary, nowMs: ms(2026, 10, 11, 7, 30), utcOffsetMin: off, rideActive: false, sentToday: 0), .send)
    }

    func testTwoADayAndTheWeeklyKeepsItsPlace() {
        let t = ms(2026, 10, 11, 7, 45)
        XCTAssertEqual(NotificationBudget.decide(.maintenance, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 1), .send)
        XCTAssertEqual(NotificationBudget.decide(.maintenance, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 2), .drop(reason: "daily limit"))
        // the weekly summary is still to come that day: only 1 slot left for the others
        XCTAssertEqual(NotificationBudget.decide(.maintenance, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 1, weeklyDueToday: true),
                       .drop(reason: "daily limit"))
        XCTAssertEqual(NotificationBudget.decide(.windPickingUp, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 0, weeklyDueToday: true), .send)
        // the weekly one itself is not blocked by the others
        XCTAssertEqual(NotificationBudget.decide(.weeklySummary, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 2), .send)
    }

    func testWindOnceADay() {
        let t = ms(2026, 10, 6, 8)
        XCTAssertEqual(NotificationBudget.decide(.windPickingUp, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 1, windSentToday: true),
                       .drop(reason: "wind already today"))
        XCTAssertEqual(NotificationBudget.decide(.windPickingUp, nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 0), .send)
    }

    func testMaintenanceDecideUsesTheSharedBudget() {
        let t = ms(2026, 10, 6, 23)
        XCTAssertEqual(Maintenance.decide(nowMs: t, utcOffsetMin: off, rideActive: false, sentToday: 0), .drop(reason: "quiet hours"))
        XCTAssertEqual(Maintenance.decide(nowMs: ms(2026, 10, 6, 12), utcOffsetMin: off, rideActive: false, sentToday: 2), .drop(reason: "daily limit"))
        XCTAssertEqual(Maintenance.decide(nowMs: ms(2026, 10, 6, 12), utcOffsetMin: off, rideActive: false, sentToday: 1), .send)
    }

    func testNextSundaySevenThirty() {
        // Monday 2026-10-05 12:00 -> Sunday 2026-10-11 07:30
        XCTAssertEqual(NotificationBudget.nextWeeklyMs(nowMs: ms(2026, 10, 5, 12), utcOffsetMin: off), ms(2026, 10, 11, 7, 30))
        // Sunday before 07:30 -> that morning; after it -> next week
        XCTAssertEqual(NotificationBudget.nextWeeklyMs(nowMs: ms(2026, 10, 11, 7, 0), utcOffsetMin: off), ms(2026, 10, 11, 7, 30))
        XCTAssertEqual(NotificationBudget.nextWeeklyMs(nowMs: ms(2026, 10, 11, 7, 30), utcOffsetMin: off), ms(2026, 10, 18, 7, 30))
        XCTAssertEqual(NotificationBudget.nextWeeklyMs(nowMs: ms(2026, 10, 11, 8, 0), utcOffsetMin: off), ms(2026, 10, 18, 7, 30))
        // Saturday night
        XCTAssertEqual(NotificationBudget.nextWeeklyMs(nowMs: ms(2026, 10, 10, 23, 30), utcOffsetMin: off), ms(2026, 10, 11, 7, 30))
    }

    func testWeeklyTalksAboutTheSevenDaysBeforeIt() {
        let fire = ms(2026, 10, 11, 7, 30)
        XCTAssertEqual(NotificationBudget.weekStart(forFireMs: fire, utcOffsetMin: off), ms(2026, 10, 4, 0))
    }

    func testLikelyRideSoonNeedsThreeUsualStartsOnThisWeekdayInTheNext2Hours() {
        let now = ms(2026, 10, 6, 7, 30)                                           // a Tuesday
        let usual = [ms(2026, 9, 29, 8, 0), ms(2026, 9, 22, 8, 15), ms(2026, 9, 15, 9, 0)]   // Tuesdays 08:00, 08:15, 09:00
        XCTAssertTrue(NotificationBudget.likelyRideSoon(startsAtMs: usual, utcOffsetsMin: [off, off, off], nowMs: now, utcOffsetMin: off))
        XCTAssertFalse(NotificationBudget.likelyRideSoon(startsAtMs: Array(usual.prefix(2)), utcOffsetsMin: [off, off], nowMs: now, utcOffsetMin: off))
        // other weekdays or other hours do not count
        let other = [ms(2026, 9, 28, 8, 0), ms(2026, 9, 21, 8, 0), ms(2026, 9, 14, 8, 0)]   // Mondays
        XCTAssertFalse(NotificationBudget.likelyRideSoon(startsAtMs: other, utcOffsetsMin: [off, off, off], nowMs: now, utcOffsetMin: off))
        let evening = [ms(2026, 9, 29, 18, 0), ms(2026, 9, 22, 18, 0), ms(2026, 9, 15, 18, 0)]
        XCTAssertFalse(NotificationBudget.likelyRideSoon(startsAtMs: evening, utcOffsetsMin: [off, off, off], nowMs: now, utcOffsetMin: off))
    }
}
