import Foundation

// M1-14: the Rides list rules, pure (no database, no time zone database). The screen feeds it one
// `RideListItem` per stored ride and shows what comes back.

/// The columns of a ride the list needs.
public struct RideListItem: Equatable, Sendable {
    public var id: String
    public var startAt: Int64          // epoch ms
    public var utcOffsetMin: Int?      // nil = unknown, the fallback offset is used
    public var kind: String            // ride / shortHop / discarded
    public var distanceM: Double?
    public var totalS: Double?

    public init(id: String, startAt: Int64, utcOffsetMin: Int? = nil, kind: String = "ride",
                distanceM: Double? = nil, totalS: Double? = nil) {
        self.id = id
        self.startAt = startAt
        self.utcOffsetMin = utcOffsetMin
        self.kind = kind
        self.distanceM = distanceM
        self.totalS = totalS
    }
}

/// Today, This week (Monday to Sunday), This month, All time
public enum RideDateFilter: String, CaseIterable, Sendable {
    case today = "Today"
    case thisWeek = "This week"
    case thisMonth = "This month"
    case allTime = "All time"
}

public struct RideDayGroup: Equatable, Sendable {
    public var day: String             // yyyy-MM-dd
    public var rides: [RideListItem]   // newest first
}

public struct RideListModel: Equatable, Sendable {
    /// The newest full ride; shown on top and not repeated in its day
    public var latest: RideListItem?
    /// Days with the remaining rides, newest day first
    public var days: [RideDayGroup]
    /// Short hops (0.5 to 2 km), collapsed by default, newest first; never in the days
    public var shortHops: [RideListItem]
    /// Rides that passed the filter (latest + days + short hops)
    public var shownCount: Int
    /// Rides stored before filtering (discarded pieces excluded)
    public var totalCount: Int

    public var isEmpty: Bool { totalCount == 0 }
    /// S10: rides exist but the filter hides them all
    public var noMatch: Bool { totalCount > 0 && shownCount == 0 }
}

public enum RideListLogic {
    /// Days since 1970-01-01 of the local calendar day of an instant.
    public static func localDay(startAt: Int64, utcOffsetMin: Int) -> Int {
        let seconds = startAt / 1000 + Int64(utcOffsetMin) * 60
        return Int((Double(seconds) / 86_400).rounded(.down))
    }

    /// yyyy-MM-dd of a day number (civil-from-days).
    public static func dayKey(_ days: Int) -> String {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return String(format: "%04d-%02d-%02d", m <= 2 ? y + 1 : y, m, d)
    }

    /// Short hop = stored as `shortHop` (the engine decides by the final distance, M36).
    public static func isShortHop(_ item: RideListItem) -> Bool { item.kind == "shortHop" }

    /// Whether the ride's own local day falls in the filter; "today" is judged at the phone's offset.
    public static func matches(_ item: RideListItem, filter: RideDateFilter, nowMs: Int64,
                               nowUtcOffsetMin: Int, fallbackUtcOffsetMin: Int) -> Bool {
        if filter == .allTime { return true }
        let rideDay = localDay(startAt: item.startAt, utcOffsetMin: item.utcOffsetMin ?? fallbackUtcOffsetMin)
        let today = localDay(startAt: nowMs, utcOffsetMin: nowUtcOffsetMin)
        switch filter {
        case .today:
            return rideDay == today
        case .thisWeek:
            let monday = today - ((today + 3) % 7)       // 1970-01-01 was a Thursday
            return rideDay >= monday && rideDay < monday + 7
        case .thisMonth:
            return dayKey(rideDay).prefix(7) == dayKey(today).prefix(7)
        case .allTime:
            return true
        }
    }

    public static func build(_ items: [RideListItem], filter: RideDateFilter, nowMs: Int64,
                             nowUtcOffsetMin: Int = 0, fallbackUtcOffsetMin: Int = 0) -> RideListModel {
        let visible = items.filter { $0.kind != "discarded" }
        let shown = visible
            .filter { matches($0, filter: filter, nowMs: nowMs, nowUtcOffsetMin: nowUtcOffsetMin,
                              fallbackUtcOffsetMin: fallbackUtcOffsetMin) }
            .sorted { $0.startAt > $1.startAt }
        let hops = shown.filter(isShortHop)
        var rides = shown.filter { !isShortHop($0) }
        let latest = rides.isEmpty ? nil : rides.removeFirst()
        var byDay: [String: [RideListItem]] = [:]
        for ride in rides {
            let key = dayKey(localDay(startAt: ride.startAt, utcOffsetMin: ride.utcOffsetMin ?? fallbackUtcOffsetMin))
            byDay[key, default: []].append(ride)
        }
        let days = byDay.keys.sorted(by: >).map { RideDayGroup(day: $0, rides: byDay[$0] ?? []) }
        return RideListModel(latest: latest, days: days, shortHops: hops, shownCount: shown.count, totalCount: visible.count)
    }
}
