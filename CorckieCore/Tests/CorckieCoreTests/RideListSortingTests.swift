import XCTest
@testable import CorckieCore

final class RideListSortingTests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000
    private let hour: Int64 = 3_600_000

    private func ride(_ id: String, _ ago: Int64, km: Double, min: Double, to: String?, used: Double?, kind: String = "ride") -> RideListItem {
        RideListItem(id: id, startAt: now - ago * hour, utcOffsetMin: 0, kind: kind, distanceM: km * 1000, totalS: min * 60,
                     endPlaceId: to, startPlaceId: "home", avgKmh: 20, usedPct: used)
    }

    private var items: [RideListItem] {
        [ride("a", 2, km: 8, min: 25, to: "work", used: 12), ride("b", 30, km: 2.5, min: 9, to: "gym", used: 3),
         ride("c", 31, km: 12, min: 35, to: "work", used: nil), ride("d", 60, km: 6, min: 20, to: nil, used: 6),
         ride("h", 1, km: 1, min: 4, to: "gym", used: 1, kind: "shortHop")]
    }

    private func build(_ sort: RideSort, query: String = "") -> RideGroups {
        RideListSorting.build(items, sort: sort, filter: .allTime, query: query,
                              names: ["home": "Home", "work": "Work", "gym": "Gym"], nowMs: now)
    }

    func test_destinationGroupsAreAlphabeticalWithNoPlaceLast() {
        XCTAssertEqual(build(.destination).groups.map(\.title), ["Gym", "Work", RideListSorting.noPlace])
    }

    func test_newestIsOnTopInEachBubble() {
        let work = build(.destination).groups.first { $0.title == "Work" }
        XCTAssertEqual(work?.rides.map(\.id), ["a", "c"])
    }

    func test_distanceDurationAndBatteryBuckets() {
        XCTAssertEqual(build(.distance).groups.map(\.title), ["10 km and more", "6 to 10 km", "Under 3 km"])
        XCTAssertEqual(build(.duration).groups.map(\.title), ["30 min and more", "20 to 30 min", "Under 10 min"])
        XCTAssertEqual(build(.battery).groups.map(\.title), ["10% and more", "5 to 10%", "Under 5%", RideListSorting.noBattery])
    }

    func test_shortHopsStayApart() {
        let m = build(.date)
        XCTAssertEqual(m.shortHops.map(\.id), ["h"])
        XCTAssertFalse(m.groups.flatMap(\.rides).contains { $0.id == "h" })
    }

    func test_searchFindsPlaceNamesAndDates() {
        XCTAssertEqual(build(.date, query: "gym").shownCount, 2)
        XCTAssertTrue(build(.date, query: "zzz").noMatch)
    }

    func test_dayTitle() {
        XCTAssertEqual(RideListSorting.dayTitle("2025-10-07"), "Tue 7 Oct")
        XCTAssertEqual(RideListSorting.dayTitle("2026-01-01"), "Thu 1 Jan")
    }
}
