import Foundation

/// M5-05: Restore merges by ride. A ride in the file is already on the phone when its id matches, or when it starts within 2 s of a ride
/// on the phone with (nearly) the same distance (the same ride written by two backups under different ids). Nothing on the phone is ever
/// overwritten or removed.
public struct RestoreRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var distanceM: Double?

    public init(id: String, startAt: Int64, distanceM: Double? = nil) {
        self.id = id
        self.startAt = startAt
        self.distanceM = distanceM
    }
}

public enum RestorePlan {
    public static let sameStartMs: Int64 = 2_000
    public static let sameDistanceShare = 0.01

    /// The ids of the incoming rides to add and the ones to skip (already there, or repeated inside the file).
    public static func decide(existing: [RestoreRide], incoming: [RestoreRide]) -> (add: [String], skip: [String]) {
        var known = existing
        var ids = Set(existing.map(\.id))
        var add: [String] = []
        var skip: [String] = []
        for ride in incoming {
            if ids.contains(ride.id) || known.contains(where: { sameRide($0, ride) }) {
                skip.append(ride.id)
            } else {
                add.append(ride.id)
                known.append(ride)
                ids.insert(ride.id)
            }
        }
        return (add, skip)
    }

    static func sameRide(_ a: RestoreRide, _ b: RestoreRide) -> Bool {
        guard abs(a.startAt - b.startAt) <= sameStartMs else { return false }
        switch (a.distanceM, b.distanceM) {
        case let (x?, y?):
            let big = max(x, y)
            return big == 0 || abs(x - y) / big <= sameDistanceShare
        default:
            return true
        }
    }
}

/// M5-05: the words after a restore
public struct RestoreReport: Equatable, Sendable {
    public var ridesAdded = 0
    public var ridesSkipped = 0
    public var ridesFailed = 0
    public var otherRows = 0
    public var source = ""

    public init() {}

    public var text: String {
        var parts: [String] = []
        parts.append(ridesAdded == 1 ? "1 ride added" : "\(ridesAdded) rides added")
        if ridesSkipped > 0 { parts.append("\(ridesSkipped) already on this phone") }
        if ridesFailed > 0 { parts.append("\(ridesFailed) could not be read") }
        if otherRows > 0 { parts.append("\(otherRows) places, routes and settings added") }
        return parts.joined(separator: ", ") + "."
    }
}

/// M5-07: raw data retention. `raw_chunk` rows (every scooter packet as received) older than the setting are deleted; the energy chunks
/// (tiny, needed for battery recalibration) and every ride row and sample stay forever.
public enum RawRetention: String, CaseIterable, Sendable {
    case days90 = "90 days"
    case year = "1 year"
    case forever = "Forever"

    public static let settingKey = "data.rawRetention"
    public static let `default` = RawRetention.days90

    public var days: Int? {
        switch self {
        case .days90: return 90
        case .year: return 365
        case .forever: return nil
        }
    }

    public init(stored: String?) {
        guard let stored, let found = RawRetention.allCases.first(where: { $0.storageValue == stored }) else {
            self = .default
            return
        }
        self = found
    }

    public var storageValue: String {
        switch self {
        case .days90: return "90d"
        case .year: return "1y"
        case .forever: return "forever"
        }
    }

    /// Chunks that ended before this time (epoch ms) are deleted; nil = keep everything
    public func cutoffMs(nowMs: Int64) -> Int64? {
        guard let days else { return nil }
        return nowMs - Int64(days) * 86_400_000
    }

    /// Kinds that are kept whatever their age
    public static let keptKinds: Set<String> = ["energy"]

    public func deletes(kind: String, endAtMs: Int64, nowMs: Int64) -> Bool {
        guard let cutoff = cutoffMs(nowMs: nowMs) else { return false }
        return !RawRetention.keptKinds.contains(kind) && endAtMs < cutoff
    }
}
