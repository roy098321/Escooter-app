import XCTest
@testable import CorckieCore

/// M1-14: Rides list grouping, Latest, short hops, date filter.
final class RideListLogicTests: XCTestCase {
    private func ms(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private func item(_ id: String, _ iso: String, kind: String = "ride", offset: Int? = 0) -> RideListItem {
        RideListItem(id: id, startAt: ms(iso), utcOffsetMin: offset, kind: kind)
    }

    /// Wednesday 2026-10-07 12:00 UTC
    private var now: Int64 { ms("2026-10-07T12:00:00Z") }

    func testGroupsByDayNewestFirstWithLatestOnTop() {
        let m = RideListLogic.build([item("a", "2026-10-05T08:00:00Z"), item("b", "2026-10-07T09:00:00Z"),
                                     item("c", "2026-10-05T17:00:00Z"), item("d", "2026-10-02T10:00:00Z")],
                                    filter: .allTime, nowMs: now)
        XCTAssertEqual(m.latest?.id, "b")
        XCTAssertEqual(m.days.map(\.day), ["2026-10-05", "2026-10-02"])
        XCTAssertEqual(m.days[0].rides.map(\.id), ["c", "a"])
        XCTAssertEqual(m.shownCount, 4)
    }

    func testShortHopsSeparateAndDiscardedHidden() {
        let m = RideListLogic.build([item("r", "2026-10-06T08:00:00Z"), item("h1", "2026-10-07T08:00:00Z", kind: "shortHop"),
                                     item("h2", "2026-10-06T09:00:00Z", kind: "shortHop"),
                                     item("x", "2026-10-07T10:00:00Z", kind: "discarded")],
                                    filter: .allTime, nowMs: now)
        XCTAssertEqual(m.latest?.id, "r")
        XCTAssertTrue(m.days.isEmpty)
        XCTAssertEqual(m.shortHops.map(\.id), ["h1", "h2"])
        XCTAssertEqual(m.totalCount, 3)
    }

    func testDayUsesTheRidesOwnOffset() {
        // 23:30 UTC on the 5th is already the 6th at +60 min
        let m = RideListLogic.build([item("a", "2026-10-05T23:30:00Z", offset: 60), item("b", "2026-10-01T10:00:00Z")],
                                    filter: .allTime, nowMs: now)
        XCTAssertEqual(m.days.map(\.day), ["2026-10-01"])
        let day = RideListLogic.localDay(startAt: m.latest!.startAt, utcOffsetMin: 60)
        XCTAssertEqual(RideListLogic.dayKey(day), "2026-10-06")
    }

    func testDateFilters() {
        let all = [item("today", "2026-10-07T01:00:00Z"), item("mon", "2026-10-05T01:00:00Z"),
                   item("sunBefore", "2026-10-04T23:00:00Z"), item("monthStart", "2026-10-01T01:00:00Z"),
                   item("sept", "2026-09-30T23:00:00Z")]
        func ids(_ f: RideDateFilter) -> Set<String> {
            let m = RideListLogic.build(all, filter: f, nowMs: now)
            return Set(([m.latest].compactMap { $0 } + m.days.flatMap(\.rides) + m.shortHops).map(\.id))
        }
        XCTAssertEqual(ids(.today), ["today"])
        XCTAssertEqual(ids(.thisWeek), ["today", "mon"])
        XCTAssertEqual(ids(.thisMonth), ["today", "mon", "sunBefore", "monthStart"])
        XCTAssertEqual(ids(.allTime).count, 5)
    }

    func testEmptyAndNoMatch() {
        XCTAssertTrue(RideListLogic.build([], filter: .allTime, nowMs: now).isEmpty)
        let m = RideListLogic.build([item("old", "2026-01-01T10:00:00Z")], filter: .today, nowMs: now)
        XCTAssertTrue(m.noMatch)
        XCTAssertFalse(m.isEmpty)
        XCTAssertNil(m.latest)
    }
}
