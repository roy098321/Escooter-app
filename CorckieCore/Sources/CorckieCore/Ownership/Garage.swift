import Foundation

/// N11-2 · O4 Garage: more than one scooter (owner 23 Nov, auto-first). Pure rules; the app keeps the list in the `setting`
/// table (`garage.registry`, scooter data in DataMap) and the per-scooter settings are swapped when the active scooter changes.
///
/// - Active scooter = the connected one; not connected -> the last one connected (= the last one ridden).
/// - An unknown scooter ID is added automatically, named after its model; its first ~10 rides are learning (no range / fault hints).
/// - Per scooter: battery, health, charge log, calibration, faults, maintenance, energy normal. Shared: places, routes, prices,
///   settings, voice. Rides with no scooter (from before the Garage) go to the scooter that was in use at the time.
/// - Leaving: Sold / Lost (owner's word; NO nearby notification) / Remove (backup first; rides stay). Sold and Lost stay read-only
///   in the list and their service book still exports.
public enum GarageStatus: String, Codable, Sendable, CaseIterable {
    case active, sold, lost, removed

    /// Sold / Lost / Removed scooters are never connected to again and are read-only.
    public var isRetired: Bool { self != .active }

    /// The plain word under the name in the list (nil for an active scooter)
    public var label: String? {
        switch self {
        case .active: return nil
        case .sold: return "Sold"
        case .lost: return "Lost"
        case .removed: return "Removed"
        }
    }
}

public struct GarageScooter: Codable, Equatable, Sendable, Identifiable {
    /// The `scooter` row id (the phone's Bluetooth identifier for it)
    public var id: String
    /// Model name from the advertised name ("RND G500"); the default display name
    public var model: String
    /// Optional name the rider gave it (app-only, the scooter is never written to)
    public var name: String?
    public var status: GarageStatus
    /// "Just borrowing": rides are kept, but the scooter is not learned (no range / fault hints from it)
    public var borrowing: Bool
    public var addedAtMs: Int64
    public var lastConnectedAtMs: Int64?
    public var retiredAtMs: Int64?

    public init(id: String, model: String, name: String? = nil, status: GarageStatus = .active, borrowing: Bool = false,
                addedAtMs: Int64, lastConnectedAtMs: Int64? = nil, retiredAtMs: Int64? = nil) {
        self.id = id
        self.model = model
        self.name = name
        self.status = status
        self.borrowing = borrowing
        self.addedAtMs = addedAtMs
        self.lastConnectedAtMs = lastConnectedAtMs
        self.retiredAtMs = retiredAtMs
    }

    public var displayName: String {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? model : n
    }
}

public struct GarageRegistry: Codable, Equatable, Sendable {
    public var scooters: [GarageScooter]
    /// The scooter whose settings are in the live (un-suffixed) setting keys right now
    public var activeId: String?
    /// Rides from before the Garage were given a scooter once
    public var legacyAssigned: Bool

    public init(scooters: [GarageScooter] = [], activeId: String? = nil, legacyAssigned: Bool = false) {
        self.scooters = scooters
        self.activeId = activeId
        self.legacyAssigned = legacyAssigned
    }

    public static let settingKey = "garage.registry"

    public static func decode(_ text: String?) -> GarageRegistry {
        guard let data = text?.data(using: .utf8), let r = try? JSONDecoder().decode(GarageRegistry.self, from: data) else { return GarageRegistry() }
        return r
    }

    public func encoded() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public func scooter(_ id: String?) -> GarageScooter? { id.flatMap { id in scooters.first { $0.id == id } } }

    /// Scooters the app still connects to (not sold, lost or removed)
    public var inUse: [GarageScooter] { scooters.filter { !$0.status.isRetired } }

    /// Own scooters in use (a borrowed one does not count for "2+ scooters")
    public var owned: [GarageScooter] { inUse.filter { !$0.borrowing } }

    /// The Garage list shows from the second scooter on; with one scooter the app looks exactly as before (P-7)
    public var showsGarage: Bool { scooters.count >= 2 }

    /// Active = the connected one; not connected -> the last one connected (retired scooters never)
    public func active(connectedId: String?) -> GarageScooter? {
        if let c = scooter(connectedId), !c.status.isRetired { return c }
        return inUse.max { ($0.lastConnectedAtMs ?? $0.addedAtMs) < ($1.lastConnectedAtMs ?? $1.addedAtMs) }
    }

    /// The scooter connected: added automatically when unknown (named after its model), else stamped. A retired scooter that
    /// connects again (e.g. sold and bought back, or found) comes back as active. Returns the new registry and whether it was new.
    public func connected(id: String, model: String, atMs: Int64) -> (GarageRegistry, isNew: Bool) {
        var r = self
        if let i = r.scooters.firstIndex(where: { $0.id == id }) {
            r.scooters[i].lastConnectedAtMs = atMs
            if r.scooters[i].status.isRetired { r.scooters[i].status = .active; r.scooters[i].retiredAtMs = nil }
            if r.scooters[i].model == Self.genericModel, model != Self.genericModel { r.scooters[i].model = model }
            return (r, false)
        }
        r.scooters.append(GarageScooter(id: id, model: model, addedAtMs: atMs, lastConnectedAtMs: atMs))
        return (r, true)
    }

    public static let genericModel = "Scooter"

    /// Sold / Lost / Remove. Nothing is deleted: rides stay, the service book still exports.
    public func retire(_ id: String, as status: GarageStatus, atMs: Int64) -> GarageRegistry {
        guard status.isRetired, let i = scooters.firstIndex(where: { $0.id == id }) else { return self }
        var r = self
        r.scooters[i].status = status
        r.scooters[i].retiredAtMs = atMs
        return r
    }

    public func renamed(_ id: String, to name: String?) -> GarageRegistry {
        guard let i = scooters.firstIndex(where: { $0.id == id }) else { return self }
        var r = self
        let t = name.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)) }
        r.scooters[i].name = (t?.isEmpty ?? true) ? nil : t
        return r
    }

    public func borrowing(_ id: String, _ on: Bool) -> GarageRegistry {
        guard let i = scooters.firstIndex(where: { $0.id == id }) else { return self }
        var r = self
        r.scooters[i].borrowing = on
        return r
    }

    /// Lock screen and charging card: the scooter's name only when the rider has 2+ scooters, else the plain word
    public func lockScreenName(activeId: String?) -> String {
        guard owned.count >= 2, let s = scooter(activeId) else { return "Scooter" }
        return s.displayName
    }
}

/// N11-2: rides recorded before the Garage have no scooter. Each goes to the scooter in use at the time: the newest scooter first
/// seen at or before the ride's start (rides before the first scooter -> the first scooter).
public enum GarageLegacy {
    public static func assign(rideStartsMs: [String: Int64], scooters: [(id: String, firstSeenMs: Int64)]) -> [String: String] {
        let ordered = scooters.sorted { $0.firstSeenMs < $1.firstSeenMs }
        guard let first = ordered.first else { return [:] }
        var out: [String: String] = [:]
        for (ride, start) in rideStartsMs {
            out[ride] = ordered.last { $0.firstSeenMs <= start }?.id ?? first.id
        }
        return out
    }
}

/// N11-2: which settings follow the scooter. When the active scooter changes, the old scooter's values are parked under
/// "<key>@<id>" and the new scooter's are put back (nothing set yet -> the key is cleared, so the new scooter learns from zero).
public enum GarageSwap {
    /// DataMap's scooter keys + the Scooter tab's look (name, colour) + learned per-scooter values kept in settings
    public static var keys: [String] { DataMap.scooterSettingKeys + ["scooter.colour", "scooter.photo.frame"] }

    public static func parked(_ key: String, _ scooterId: String) -> String { "\(key)@\(scooterId)" }

    public struct Step: Equatable, Sendable {
        /// (from, to) copies; a nil source value means "clear the target"
        public var moves: [(from: String, to: String)]
        public static func == (a: Step, b: Step) -> Bool { a.moves.map { "\($0.from)>\($0.to)" } == b.moves.map { "\($0.from)>\($0.to)" } }
    }

    /// The copies to make, in order: park the old scooter's live values, then load the new scooter's parked ones.
    public static func plan(from old: String?, to new: String) -> Step {
        guard old != new else { return Step(moves: []) }
        var moves: [(String, String)] = []
        if let old { for k in keys { moves.append((k, parked(k, old))) } }
        for k in keys { moves.append((parked(k, new), k)) }
        return Step(moves: moves)
    }
}

/// N11-2: the Stats filter: all scooters by default; one entry per scooter once there are 2+.
public enum GarageStatsFilter: Equatable, Sendable, Hashable {
    case all
    case scooter(String)

    public static func options(_ registry: GarageRegistry) -> [GarageStatsFilter] {
        registry.scooters.count >= 2 ? [.all] + registry.scooters.map { .scooter($0.id) } : [.all]
    }

    public func includes(rideScooterId: String?) -> Bool {
        switch self {
        case .all: return true
        case let .scooter(id): return rideScooterId == id
        }
    }

    public func label(_ registry: GarageRegistry) -> String {
        switch self {
        case .all: return "All scooters"
        case let .scooter(id): return registry.scooter(id)?.displayName ?? "Scooter"
        }
    }
}

/// N11-2: a new scooter learns first: no range / fault hints before ~10 of ITS rides (a borrowed one never leaves learning)
public enum GarageLearning {
    public static let rides = 10

    public static func isLearning(ridesOnScooter: Int, borrowing: Bool) -> Bool { borrowing || ridesOnScooter < rides }
}
