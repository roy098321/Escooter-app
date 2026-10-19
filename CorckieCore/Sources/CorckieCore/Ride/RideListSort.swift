import Foundation

/// F-07: how the Rides list is grouped into bubbles ("Sort by:"). Inside every bubble the newest ride is on top.
public enum RideSort: String, CaseIterable, Sendable {
    case date = "Date"
    case destination = "Destination"
    case dayOfWeek = "Day of week"
    case timeOfDay = "Time of day"
    case distance = "Distance"
    case duration = "Duration"
    case battery = "Battery used"
}

public struct RideGroup: Equatable, Sendable {
    public var title: String
    public var rides: [RideListItem]   // newest first
}

public struct RideGroups: Equatable, Sendable {
    public var groups: [RideGroup]
    /// short hops (0.5 to 2 km), newest first, never in the groups
    public var shortHops: [RideListItem]
    public var shownCount: Int
    public var totalCount: Int
    public var isEmpty: Bool { totalCount == 0 }
    public var noMatch: Bool { totalCount > 0 && shownCount == 0 }
}

public enum RideListSorting {
    public static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    public static let noPlace = "No saved place"
    public static let noBattery = "No battery data"

    /// "Tue 7 Oct" from "2025-10-07"
    public static func dayTitle(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[1] >= 1, parts[1] <= 12 else { return key }
        var y = parts[0]
        let m = parts[1], d = parts[2]
        if m <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = m > 2 ? m - 3 : m + 9
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let wd = ((days + 4) % 7 + 7) % 7
        return "\(weekdays[wd].prefix(3)) \(d) \(months[m - 1])"
    }

    private static func localSeconds(_ r: RideListItem, _ fallback: Int) -> Int64 {
        r.startAt / 1000 + Int64(r.utcOffsetMin ?? fallback) * 60
    }

    /// bucket (sort order, title) of a ride for a sort mode
    static func bucket(_ r: RideListItem, _ sort: RideSort, names: [String: String], fallback: Int) -> (Int, String) {
        let secs = localSeconds(r, fallback)
        let day = Int((Double(secs) / 86_400).rounded(.down))
        switch sort {
        case .date:
            return (-day, dayTitle(RideListLogic.dayKey(day)))
        case .destination:
            if let id = r.endPlaceId, let n = names[id], !n.isEmpty { return (0, n) }
            return (1, noPlace)
        case .dayOfWeek:
            let wd = ((day + 3) % 7 + 7) % 7      // 0 = Monday
            return (wd, weekdays[(wd + 1) % 7])
        case .timeOfDay:
            let h = Int(((secs % 86_400) + 86_400) % 86_400) / 3_600
            switch h {
            case 5..<12: return (0, "Morning")
            case 12..<17: return (1, "Afternoon")
            case 17..<22: return (2, "Evening")
            default: return (3, "Night")
            }
        case .distance:
            let km = (r.distanceM ?? 0) / 1000
            if km >= 10 { return (0, "10 km and more") }
            if km >= 6 { return (1, "6 to 10 km") }
            if km >= 3 { return (2, "3 to 6 km") }
            return (3, "Under 3 km")
        case .duration:
            let min = (r.totalS ?? 0) / 60
            if min >= 30 { return (0, "30 min and more") }
            if min >= 20 { return (1, "20 to 30 min") }
            if min >= 10 { return (2, "10 to 20 min") }
            return (3, "Under 10 min")
        case .battery:
            guard let p = r.usedPct else { return (3, noBattery) }
            if p >= 10 { return (0, "10% and more") }
            if p >= 5 { return (1, "5 to 10%") }
            return (2, "Under 5%")
        }
    }

    /// A search matches a place name (start or end) or the date text ("Tue 7 Oct", "oct").
    static func matches(_ r: RideListItem, query: String, names: [String: String], fallback: Int) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        for id in [r.startPlaceId, r.endPlaceId].compactMap({ $0 }) {
            if let n = names[id], n.lowercased().contains(q) { return true }
        }
        let day = RideListLogic.localDay(startAt: r.startAt, utcOffsetMin: r.utcOffsetMin ?? fallback)
        return dayTitle(RideListLogic.dayKey(day)).lowercased().contains(q)
    }

    public static func build(_ items: [RideListItem], sort: RideSort, filter: RideDateFilter, query: String = "",
                             names: [String: String] = [:], nowMs: Int64, nowUtcOffsetMin: Int = 0,
                             fallbackUtcOffsetMin: Int = 0) -> RideGroups {
        let visible = items.filter { $0.kind != "discarded" }
        let shown = visible
            .filter { RideListLogic.matches($0, filter: filter, nowMs: nowMs, nowUtcOffsetMin: nowUtcOffsetMin, fallbackUtcOffsetMin: fallbackUtcOffsetMin) }
            .filter { matches($0, query: query, names: names, fallback: fallbackUtcOffsetMin) }
            .sorted { $0.startAt > $1.startAt }
        let hops = shown.filter(RideListLogic.isShortHop)
        var buckets: [String: (order: Int, rides: [RideListItem])] = [:]
        for r in shown where !RideListLogic.isShortHop(r) {
            let (order, title) = bucket(r, sort, names: names, fallback: fallbackUtcOffsetMin)
            var entry = buckets[title] ?? (order, [])
            entry.rides.append(r)
            buckets[title] = entry
        }
        // destination bubbles run A to Z (no saved place last); every other mode runs in its natural order
        let ordered = buckets.sorted { a, b in
            if a.value.order != b.value.order { return a.value.order < b.value.order }
            return sort == .destination ? a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending : a.key < b.key
        }
        return RideGroups(groups: ordered.map { RideGroup(title: $0.key, rides: $0.value.rides) }, shortHops: hops,
                          shownCount: shown.count, totalCount: visible.count)
    }
}
