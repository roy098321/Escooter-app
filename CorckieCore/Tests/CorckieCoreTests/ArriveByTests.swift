import XCTest
@testable import CorckieCore

/// M2-07: Arrive by (M29) and the leave-by reminder (T84, T98 quiet hours).
final class ArriveByTests: XCTestCase {
    static let day: Int64 = 86_400_000
    /// 20717 = a Monday (workday, weekday 1)
    static let monday: Int64 = 20_717

    private func ride(_ id: String, dayNumber: Int64, hour: Int, minute: Int = 0, totalS: Double) -> RouteRideStats {
        RouteRideStats(rideId: id, startAt: dayNumber * Self.day + Int64(hour * 60 + minute) * 60_000, utcOffsetMin: 0, totalS: totalS,
                       distanceM: 3_700, avgMovingMps: 7, usedPct: 8)
    }

    private func ms(day: Int64, _ hour: Int, _ minute: Int = 0) -> Int64 { day * Self.day + Int64(hour * 60 + minute) * 60_000 }

    /// 3 rush-hour rides of 20 min, 3 midday rides of 10 min, all on workdays (the split of T65)
    private var splitRides: [RouteRideStats] {
        [ride("a0", dayNumber: Self.monday - 1, hour: 8, totalS: 1_200), ride("a1", dayNumber: Self.monday - 4, hour: 8, totalS: 1_200),
         ride("a2", dayNumber: Self.monday - 5, hour: 8, totalS: 1_200),
         ride("b0", dayNumber: Self.monday - 6, hour: 12, totalS: 600), ride("b1", dayNumber: Self.monday - 7, hour: 12, totalS: 600),
         ride("b2", dayNumber: Self.monday - 8, hour: 12, totalS: 600)]
    }

    func test_plainRoute_leaveIsTargetMinusTodayMinusMargin() throws {
        let rides = [ride("a", dayNumber: Self.monday - 1, hour: 12, totalS: 540), ride("b", dayNumber: Self.monday - 4, hour: 12, totalS: 600),
                     ride("c", dayNumber: Self.monday - 5, hour: 12, totalS: 780)]
        let target = ms(day: Self.monday, 14)
        let plan = try XCTUnwrap(ArriveBy.plan(rides: rides, targetAtMs: target, utcOffsetMin: 0).plan)
        XCTAssertEqual(plan.todayS, 600, accuracy: 0.5)
        XCTAssertEqual(plan.marginS, 180, accuracy: 0.5, "upper edge 13 min minus the median 10 min")
        XCTAssertEqual(plan.leaveAtMs, target - 13 * 60_000)
        XCTAssertEqual(plan.headline, "Leave by 13:47")
        XCTAssertEqual(plan.detail, "10 min today + 3 min margin \u{00B7} to arrive by 14:00")
        XCTAssertLessThanOrEqual(plan.iterations, ArriveBy.maxIterations)
    }

    func test_rushHourBoundary_iteratesAndConvergesInAtMostThree() throws {
        let rides = splitRides
        XCTAssertNotNil(UsualRange.timeSplit(rides), "the data splits on rush hour")
        // arrive by 9:40: leaving 9:30 (rush, 20 min) is too late, so the leave moves to 9:20, which is rush too: 2 passes
        let plan = try XCTUnwrap(ArriveBy.plan(rides: rides, targetAtMs: ms(day: Self.monday, 9, 40), utcOffsetMin: 0).plan)
        XCTAssertEqual(plan.leaveAtMs, ms(day: Self.monday, 9, 20))
        XCTAssertTrue(plan.rushHourAtLeave)
        XCTAssertLessThanOrEqual(plan.iterations, 3)
        XCTAssertEqual(plan.todayS, 1_200, accuracy: 0.5)
        // arrive by 10:30: leave 10:20, outside rush hour, 10 min
        let calm = try XCTUnwrap(ArriveBy.plan(rides: rides, targetAtMs: ms(day: Self.monday, 10, 30), utcOffsetMin: 0).plan)
        XCTAssertEqual(calm.leaveAtMs, ms(day: Self.monday, 10, 20))
        XCTAssertFalse(calm.rushHourAtLeave)
        XCTAssertEqual(calm.iterations, 1, "already converged after one pass")
    }

    func test_notEnoughRides() {
        let two = [ride("a", dayNumber: Self.monday - 1, hour: 8, totalS: 600), ride("b", dayNumber: Self.monday - 4, hour: 8, totalS: 600)]
        XCTAssertEqual(ArriveBy.plan(rides: two, targetAtMs: ms(day: Self.monday, 9), utcOffsetMin: 0), .notEnough(have: 2, need: 3))
    }

    func test_nextTarget_isTheNextTimeTheClockShowsIt() {
        let now = ms(day: Self.monday, 10)
        XCTAssertEqual(ArriveBy.nextTargetMs(minuteOfDay: 8 * 60, nowMs: now, utcOffsetMin: 0), ms(day: Self.monday + 1, 8))
        XCTAssertEqual(ArriveBy.nextTargetMs(minuteOfDay: 18 * 60, nowMs: now, utcOffsetMin: 0), ms(day: Self.monday, 18))
        // +3 h local: now is 13:00 local, 8:00 local is tomorrow 05:00 UTC
        XCTAssertEqual(ArriveBy.nextTargetMs(minuteOfDay: 8 * 60, nowMs: now, utcOffsetMin: 180), ms(day: Self.monday + 1, 5))
    }

    // MARK: reminder

    func test_reminder_sentAtTheLeaveTime() {
        let now = ms(day: Self.monday, 6)
        XCTAssertEqual(LeaveReminder.decide(leaveAtMs: ms(day: Self.monday, 8, 30), targetAtMs: ms(day: Self.monday, 9), nowMs: now, utcOffsetMin: 0),
                       .send(atMs: ms(day: Self.monday, 8, 30), held: false))
    }

    func test_reminder_quietHours_heldToSevenOrDropped() {
        let now = ms(day: Self.monday, 1)
        // leave 06:30, arrive by 07:45: held to 07:00
        XCTAssertEqual(LeaveReminder.decide(leaveAtMs: ms(day: Self.monday, 6, 30), targetAtMs: ms(day: Self.monday, 7, 45), nowMs: now, utcOffsetMin: 0),
                       .send(atMs: ms(day: Self.monday, 7), held: true))
        // leave 06:30, arrive by 06:58: 07:00 is too late to matter
        XCTAssertEqual(LeaveReminder.decide(leaveAtMs: ms(day: Self.monday, 6, 30), targetAtMs: ms(day: Self.monday, 6, 58), nowMs: now, utcOffsetMin: 0),
                       .drop(reason: "quiet hours, no longer relevant"))
        // leave 22:30 in the evening: 07:00 next morning is after the target
        let noon = ms(day: Self.monday, 12)
        XCTAssertEqual(LeaveReminder.decide(leaveAtMs: ms(day: Self.monday, 22, 30), targetAtMs: ms(day: Self.monday, 23, 30), nowMs: noon, utcOffsetMin: 0),
                       .drop(reason: "quiet hours, no longer relevant"))
        // +3 h zone: leave 21:00 UTC = 00:00 local, held to 07:00 local = 04:00 UTC the next day, target 05:30 UTC
        XCTAssertEqual(LeaveReminder.decide(leaveAtMs: ms(day: Self.monday, 21), targetAtMs: ms(day: Self.monday + 1, 5, 30), nowMs: noon, utcOffsetMin: 180),
                       .send(atMs: ms(day: Self.monday + 1, 4), held: true))
    }

    func test_reminder_pastOrDuringARide_dropped() {
        let now = ms(day: Self.monday, 9)
        XCTAssertEqual(LeaveReminder.decide(leaveAtMs: ms(day: Self.monday, 8, 59), targetAtMs: ms(day: Self.monday, 9, 30), nowMs: now, utcOffsetMin: 0),
                       .drop(reason: "leave time already passed"))
        XCTAssertEqual(LeaveReminder.decide(leaveAtMs: ms(day: Self.monday, 12), targetAtMs: ms(day: Self.monday, 13), nowMs: now, utcOffsetMin: 0, rideActive: true),
                       .drop(reason: "ride active"))
    }

    func test_reminder_updatesOnlyWhenTwoMinutesOrMoreEarlier() {
        let old = ms(day: Self.monday, 8, 30)
        XCTAssertTrue(LeaveReminder.shouldReplace(oldLeaveAtMs: nil, newLeaveAtMs: old))
        XCTAssertTrue(LeaveReminder.shouldReplace(oldLeaveAtMs: old, newLeaveAtMs: old - 120_000))
        XCTAssertFalse(LeaveReminder.shouldReplace(oldLeaveAtMs: old, newLeaveAtMs: old - 119_000))
        XCTAssertFalse(LeaveReminder.shouldReplace(oldLeaveAtMs: old, newLeaveAtMs: old + 600_000))
    }

    func test_reminder_text() throws {
        let plan = try XCTUnwrap(ArriveBy.plan(rides: splitRides, targetAtMs: ms(day: Self.monday, 10, 30), utcOffsetMin: 0).plan)
        let t = LeaveReminder.text(destination: "Work", plan: plan, utcOffsetMin: 0)
        XCTAssertEqual(t.title, "Time to leave")
        XCTAssertEqual(t.body, "Leave now to arrive at Work by 10:30 (about 10 min + 0 min margin).")
    }
}
