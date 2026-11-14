import XCTest
@testable import CorckieCore

/// D2 option C: the milestones tick from facts; the group goes away after the report or 30 days
final class NewScooterWeekTests: XCTestCase {
    func test_nothingTicksBeforeAFreshStart() {
        let f = NewScooterWeek.Facts()
        for m in NewScooterWeek.milestones { XCTAssertFalse(NewScooterWeek.isDone(m.id, f), m.id) }
    }

    func test_ridesTickTheRideMilestones() {
        var f = NewScooterWeek.Facts()
        f.startedFresh = true
        f.rides = 1
        XCTAssertTrue(NewScooterWeek.isDone("M0", f))
        XCTAssertTrue(NewScooterWeek.isDone("M2", f))
        XCTAssertFalse(NewScooterWeek.isDone("M5", f))
        f.rides = 5
        XCTAssertTrue(NewScooterWeek.isDone("M5", f))
        XCTAssertFalse(NewScooterWeek.isDone("M6", f))
        f.rides = 10
        XCTAssertTrue(NewScooterWeek.isDone("M6", f))
    }

    func test_routeRideThreeNeedsThreeRidesOnOneRoute() {
        var f = NewScooterWeek.Facts()
        f.bestRouteRides = 2
        XCTAssertFalse(NewScooterWeek.isDone("M4", f))
        f.bestRouteRides = 3
        XCTAssertTrue(NewScooterWeek.isDone("M4", f))
    }

    func test_groupLifetime() {
        let day: Int64 = 86_400_000
        XCTAssertFalse(NewScooterWeek.isActive(startedAtMs: nil, sharedAtMs: nil, nowMs: 100 * day))
        XCTAssertTrue(NewScooterWeek.isActive(startedAtMs: 10 * day, sharedAtMs: nil, nowMs: 20 * day))
        XCTAssertFalse(NewScooterWeek.isActive(startedAtMs: 10 * day, sharedAtMs: 15 * day, nowMs: 20 * day), "gone once the report is shared")
        XCTAssertFalse(NewScooterWeek.isActive(startedAtMs: 10 * day, sharedAtMs: nil, nowMs: 41 * day), "gone after 30 days")
    }

    func test_reportHasNoThumbsAndShowsNotes() {
        var f = NewScooterWeek.Facts()
        f.startedFresh = true
        let text = NewScooterWeek.report(f, notes: ["M0": "backup is in Files"])
        XCTAssertTrue(text.contains("done \u{00B7} M0 Fresh start \u{00B7} backup is in Files"))
        XCTAssertTrue(text.contains("waiting \u{00B7} M2 Ride 1"))
        XCTAssertFalse(text.contains("\u{1F44D}"))
    }
}
