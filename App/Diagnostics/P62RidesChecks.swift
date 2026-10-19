import CorckieCore
import Foundation

/// u65 (P6-2 chunk 2b): the Rides list sorts into bubbles, the ride detail shows heat only when hot, and the row figures are one line.
extension P62Checks {
    @MainActor static func runRides() {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        let now: Int64 = 1_790_000_000_000
        let h: Int64 = 3_600_000
        func ride(_ id: String, _ ago: Int64, km: Double, min: Double, to: String?, used: Double?) -> RideListItem {
            RideListItem(id: id, startAt: now - ago * h, utcOffsetMin: 0, kind: "ride", distanceM: km * 1000, totalS: min * 60,
                         endPlaceId: to, startPlaceId: "home", avgKmh: km / (min / 60), usedPct: used)
        }
        let items = [ride("a", 2, km: 8, min: 25, to: "work", used: 12), ride("b", 30, km: 2.5, min: 9, to: "gym", used: 3),
                     ride("c", 31, km: 12, min: 35, to: "work", used: nil), ride("d", 60, km: 6, min: 20, to: nil, used: 6)]
        let names = ["home": "Home", "work": "Work", "gym": "Gym"]
        func groups(_ sort: RideSort, _ query: String = "") -> RideGroups {
            RideListSorting.build(items, sort: sort, filter: .allTime, query: query, names: names, nowMs: now)
        }
        let dest = groups(.destination)
        expect(dest.groups.map(\.title) == ["Gym", "Work", RideListSorting.noPlace], "Destination: A to Z, no saved place last")
        expect(dest.groups.first { $0.title == "Work" }?.rides.map(\.id) == ["a", "c"], "newest ride on top in a bubble")
        expect(groups(.distance).groups.map(\.title) == ["10 km and more", "6 to 10 km", "Under 3 km"], "Distance bubbles run longest first")
        expect(groups(.battery).groups.map(\.title) == ["10% and more", "5 to 10%", "Under 5%", RideListSorting.noBattery], "Battery used bubbles")
        expect(groups(.duration).groups.map(\.title) == ["30 min and more", "20 to 30 min", "Under 10 min"], "Duration bubbles")
        expect(RideListSorting.dayTitle("2025-10-07") == "Tue 7 Oct", "day title Tue 7 Oct")
        expect(groups(.dayOfWeek).groups.allSatisfy { RideListSorting.weekdays.contains($0.title) }, "Day of week bubbles")
        expect(groups(.timeOfDay).groups.allSatisfy { ["Morning", "Afternoon", "Evening", "Night"].contains($0.title) }, "Time of day bubbles")
        expect(groups(.date, "gym").shownCount == 1 && groups(.date, "zzz").noMatch, "search finds a place name, and nothing")
        let line = RidesListView.figures(items[0])
        expect(line == "8.0 km \u{00B7} 25 min \u{00B7} 19 km/h \u{00B7} 12%", "row figures on one line: \(line)")
        var hot = RideDetailInput(startAt: now, totalS: 600)
        hot.tempPeakC = 95
        var cool = hot
        cool.tempPeakC = 30
        let isHot = RideSummaryBuilder.build(hot, gaps: [], points: []).hotPeakC == 95
        let isCool = RideSummaryBuilder.build(cool, gaps: [], points: []).hotPeakC == nil
        expect(isHot && isCool, "temperature only when hot")
        CheckResults.shared.set("u65", ok ? .pass : .fail, notes.joined(separator: " \u{00B7} "))
    }
}
