import Foundation

/// M3-06: maintenance by km (FEATURES "Maintenance reminders", CALC_SPEC 9.4 "Maintenance", C14).
/// Pure logic: which items are due, the one reminder per item (again after 3 days if not marked done), and the notification
/// rules (quiet hours 22:00 to 07:00, at most 2 a day, never during a ride). Storage and the notification are in the App layer.

public struct MaintenanceItem: Equatable, Sendable {
    public var id: String
    public var name: String
    /// What to do, shown under the name
    public var hint: String
    public var intervalKm: Double?
    public var intervalDays: Double?
    /// Odometer (km) when it was last done, or when the app started counting
    public var lastDoneOdoKm: Double?
    public var lastDoneAt: Int64?
    /// When the reminder was last sent (epoch ms)
    public var notifiedAt: Int64?

    public init(id: String, name: String, hint: String, intervalKm: Double?, intervalDays: Double?, lastDoneOdoKm: Double?,
                lastDoneAt: Int64?, notifiedAt: Int64? = nil) {
        self.id = id
        self.name = name
        self.hint = hint
        self.intervalKm = intervalKm
        self.intervalDays = intervalDays
        self.lastDoneOdoKm = lastDoneOdoKm
        self.lastDoneAt = lastDoneAt
        self.notifiedAt = notifiedAt
    }
}

public enum MaintenanceStatus: Equatable, Sendable {
    /// Nothing to do yet; km left (nil when the item has no km interval)
    case ok(kmLeft: Double?)
    /// Due by km; km past the interval
    case dueKm(over: Double)
    /// Due by days; days past the interval
    case dueDays(over: Double)
    /// Never started (no odometer yet)
    case notStarted

    public var isDue: Bool {
        switch self {
        case .dueKm, .dueDays: return true
        default: return false
        }
    }
}

public enum MaintenanceDecision: Equatable, Sendable {
    case send
    case drop(reason: String)
}

public enum Maintenance {
    public static let messageType = "maintenance"
    /// A reminder is repeated after 3 days when the item is not marked done
    public static let repeatAfterMs: Int64 = 3 * 86_400_000

    /// Defaults (editable later). Tyres 50 PSI and 300 km / 14 days come from CALC_SPEC 9.4; brakes and bolts are a guess
    /// until the RND manual is read.
    public static func defaults(odoKm: Double?, nowMs: Int64) -> [MaintenanceItem] {
        [
            MaintenanceItem(id: "tyres", name: "Tyre pressure", hint: "Check the pressure: 50 PSI", intervalKm: 300, intervalDays: 14,
                            lastDoneOdoKm: odoKm, lastDoneAt: nowMs),
            MaintenanceItem(id: "brakes", name: "Brakes", hint: "Check the pads and the brake feel", intervalKm: 500, intervalDays: nil,
                            lastDoneOdoKm: odoKm, lastDoneAt: nowMs),
            MaintenanceItem(id: "bolts", name: "Bolts and folding joint", hint: "Check that bolts and the folding joint are tight",
                            intervalKm: 300, intervalDays: nil, lastDoneOdoKm: odoKm, lastDoneAt: nowMs),
        ]
    }

    public static func status(_ item: MaintenanceItem, odoKm: Double?, nowMs: Int64) -> MaintenanceStatus {
        var kmLeft: Double?
        if let interval = item.intervalKm {
            guard let odo = odoKm, let last = item.lastDoneOdoKm else { return .notStarted }
            let left = interval - max(0, odo - last)
            if left <= 0 { return .dueKm(over: -left) }
            kmLeft = left
        }
        if let days = item.intervalDays, let at = item.lastDoneAt {
            let over = Double(nowMs - at) / 86_400_000 - days
            if over >= 0 { return .dueDays(over: over) }
        }
        return .ok(kmLeft: kmLeft)
    }

    public static func statusText(_ s: MaintenanceStatus) -> String {
        switch s {
        case .ok(let left): return left.map { "\(Int($0.rounded())) km left" } ?? "OK"
        case .dueKm(let over): return over < 1 ? "Due now" : "Due, \(Int(over.rounded())) km over"
        case .dueDays(let over): return over < 1 ? "Due now" : "Due, \(Int(over.rounded())) days over"
        case .notStarted: return "Counting starts with the first ride"
        }
    }

    /// Mark done: counting starts again from the current odometer and the clock
    public static func markedDone(_ item: MaintenanceItem, odoKm: Double?, nowMs: Int64) -> MaintenanceItem {
        var i = item
        i.lastDoneOdoKm = odoKm
        i.lastDoneAt = nowMs
        i.notifiedAt = nil
        return i
    }

    /// Items that need a reminder now, after a ride ends: due, and never reminded or reminded 3 or more days ago.
    public static func toRemind(_ items: [MaintenanceItem], odoKm: Double?, nowMs: Int64) -> [MaintenanceItem] {
        items.filter { item in
            guard status(item, odoKm: odoKm, nowMs: nowMs).isDue else { return false }
            guard let last = item.notifiedAt else { return true }
            return nowMs - last >= repeatAfterMs
        }
    }

    /// The notification rules (CALC_SPEC 9.4): never during a ride, not in quiet hours (an item not marked sent is checked again
    /// at the next ride end, so nothing is lost), at most 2 notifications a day (Arrive-by excluded; `sentToday` counts the others).
    public static func decide(nowMs: Int64, utcOffsetMin: Int, rideActive: Bool, sentToday: Int) -> MaintenanceDecision {
        if rideActive { return .drop(reason: "ride active") }
        let local = nowMs + Int64(utcOffsetMin) * 60_000
        let hour = Int(((local / 3_600_000) % 24 + 24) % 24)
        if hour >= T.t98QuietFromHour || hour < T.t98QuietToHour { return .drop(reason: "quiet hours") }
        if sentToday >= T.t98NotificationsPerDay { return .drop(reason: "daily limit") }
        return .send
    }

    public static func text(_ item: MaintenanceItem, status: MaintenanceStatus) -> (title: String, body: String) {
        ("\(item.name) due", "\(statusText(status)). \(item.hint). Open Settings → Maintenance and mark it done.")
    }
}
