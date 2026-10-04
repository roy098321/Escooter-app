import CorckieCore
import Foundation

/// u8 (M1-14): the Rides list rules on made-up rides stored in a temporary database (the real one is never
/// touched): grouped by day, Latest on top, short hop kept apart, discarded hidden, date filter, delete.
enum RideListCheck {
    static func run() {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u8", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let store = RideQueries(temp)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let hour: Int64 = 3_600_000
            let day: Int64 = 24 * hour
            func save(_ id: String, _ ago: Int64, _ kind: String) throws {
                var r = RideRecord(id: id, startAt: now - ago)
                r.kind = kind
                r.utcOffsetMin = 0
                r.isSimulated = true
                try store.save(r)
            }
            try save("a", 0, "ride")
            try save("b", 40 * day, "ride")
            try save("c", 41 * day, "ride")
            try save("h", 2 * hour, "shortHop")
            try save("x", 3 * hour, "discarded")
            func list(_ f: RideDateFilter) throws -> RideListModel {
                let items = try store.rides().map {
                    RideListItem(id: $0.id, startAt: $0.startAt, utcOffsetMin: $0.utcOffsetMin, kind: $0.kind)
                }
                return RideListLogic.build(items, filter: f, nowMs: now)
            }
            let all = try list(.allTime)
            let groupsOk = all.latest?.id == "a" && all.shortHops.map(\.id) == ["h"]
                && all.days.flatMap(\.rides).map(\.id) == ["b", "c"] && all.totalCount == 4
            let filterOk = try list(.today).shownCount <= 2 && list(.thisWeek).latest?.id == "a"
            _ = try store.delete(rideId: "b")
            let afterDelete = try list(.allTime)
            let deleteOk = afterDelete.days.flatMap(\.rides).map(\.id) == ["c"]
            let ok = groupsOk && filterOk && deleteOk
            results.set("u8", ok ? .pass : .fail,
                        "Latest/day grouping \(groupsOk ? "ok" : "wrong") · short hop kept apart, discarded hidden · date filter \(filterOk ? "ok" : "wrong") · delete \(deleteOk ? "ok" : "wrong")")
        } catch {
            results.set("u8", .fail, "Rides list check failed: \(error.localizedDescription)")
        }
    }
}
