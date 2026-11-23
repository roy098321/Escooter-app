import CorckieCore
import Foundation
import GRDB

/// N11-2 · O4 Garage (owner 23 Nov, auto-first). The list lives in the `setting` table (`garage.registry`, no schema change).
///
/// How the rest of the app follows the active scooter without knowing about the Garage:
/// - only the ACTIVE scooter's `scooter` row has `forgottenAt IS NULL`, so `ScooterRecord.latest` (faults, maintenance, service book,
///   low-battery power) and `BatteryDoor` (calibration, real range, health, charges) read the active scooter's data only;
/// - the per-scooter settings (pack size, charger, learned Ah, charging speed, name, colour, photo) are swapped (`GarageSwap`);
/// - every new ride and charge is tagged with the active scooter's id.
/// Nothing is ever written to a scooter (Bluetooth stays read-only).
enum GarageService {
    /// Set by the app: moves the Scooter tab photo with its scooter (ScooterPhotoStore.swap). Not set in AppTests (no UI there).
    static var onSwap: ((_ from: String?, _ to: String) -> Void)?
    /// N11-2: "Just borrowing" was tapped in Add a scooter; applied when that scooter's row is first saved
    static var pendingBorrowId: String?

    static func registry(_ db: AppDatabase?) -> GarageRegistry {
        GarageRegistry.decode(SettingsValue.text(db, GarageRegistry.settingKey))
    }

    static func save(_ r: GarageRegistry, _ db: AppDatabase?) {
        SettingsValue.set(db, GarageRegistry.settingKey, r.encoded())
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// The active scooter's id (nil before any scooter was connected)
    static func activeId(_ db: AppDatabase?) -> String? { registry(db).activeId }

    /// The first launch of Batch 11: the Garage starts from the `scooter` rows already on the phone (the newest one not forgotten
    /// is active; a forgotten one is listed as Removed, its rides stay) and older rides without a scooter are given one.
    static func bootstrap(_ db: AppDatabase) {
        guard !db.isReadOnly else { return }
        var r = registry(db)
        if r.scooters.isEmpty {
            let rows: [Row] = (try? db.writer.read { d -> [Row] in
                try Row.fetchAll(d, sql: "SELECT id, name, firstSeenAt, forgottenAt FROM scooter WHERE id != 'previous' ORDER BY firstSeenAt")
            }) ?? []
            for row in rows {
                let id: String = row["id"]
                let name: String? = row["name"]
                let first: Int64? = row["firstSeenAt"]
                let forgotten: Int64? = row["forgottenAt"]
                r.scooters.append(GarageScooter(id: id, model: NewRider.cardName(foundModel: name), status: forgotten == nil ? .active : .removed,
                                                addedAtMs: first ?? 0, lastConnectedAtMs: first, retiredAtMs: forgotten))
            }
            r.activeId = r.active(connectedId: nil)?.id
        }
        if !r.legacyAssigned, !r.scooters.isEmpty {
            assignLegacy(db, r)
            r.legacyAssigned = true
        }
        save(r, db)
    }

    /// Rides from before the Garage (no scooter) go to the scooter in use at the time
    private static func assignLegacy(_ db: AppDatabase, _ r: GarageRegistry) {
        let scooters = r.scooters.map { (id: $0.id, firstSeenMs: $0.addedAtMs) }
        guard !scooters.isEmpty else { return }
        try? db.writer.write { d in
            let rides = try Row.fetchAll(d, sql: "SELECT id, startAt FROM ride WHERE scooterId IS NULL")
            var starts: [String: Int64] = [:]
            for row in rides { starts[row["id"]] = row["startAt"] }
            for (ride, scooter) in GarageLegacy.assign(rideStartsMs: starts, scooters: scooters) {
                try d.execute(sql: "UPDATE ride SET scooterId = ? WHERE id = ? AND scooterId IS NULL", arguments: [scooter, ride])
            }
            // charges need no tag: they are derived from the rides again and again (CalibrationUpdater, through BatteryDoor)
        }
    }

    /// A scooter connected (its `scooter` row is saved): it is added if unknown and becomes the active one. When the active scooter
    /// changes, the old one's settings and photo are parked and the new one's put back. Returns true for a scooter new to the Garage.
    @discardableResult
    static func connected(id: String, model: String, _ db: AppDatabase) -> Bool {
        guard !db.isReadOnly else { return false }
        var (r, isNew) = registry(db).connected(id: id, model: model, atMs: nowMs())
        if isNew, pendingBorrowId == id { r = r.borrowing(id, true) }
        if pendingBorrowId == id { pendingBorrowId = nil }
        let old = r.activeId
        if old != id {
            swapSettings(from: old, to: id, db)
            onSwap?(old, id)
            r.activeId = id
        }
        save(r, db)
        markActiveRow(id, db)
        return isNew
    }

    /// Only the active scooter's row is "not forgotten" (see the type comment)
    private static func markActiveRow(_ id: String, _ db: AppDatabase) {
        let now = nowMs()
        try? db.writer.write { d in
            try d.execute(sql: "UPDATE scooter SET forgottenAt = COALESCE(forgottenAt, ?) WHERE id != ?", arguments: [now, id])
            try d.execute(sql: "UPDATE scooter SET forgottenAt = NULL WHERE id = ?", arguments: [id])
        }
    }

    private static func swapSettings(from old: String?, to new: String, _ db: AppDatabase) {
        let plan = GarageSwap.plan(from: old, to: new)
        try? db.writer.write { d in
            for m in plan.moves {
                if let v = try String.fetchOne(d, sql: "SELECT json FROM setting WHERE key = ?", arguments: [m.from]) {
                    try d.execute(sql: "INSERT OR REPLACE INTO setting (key, json) VALUES (?, ?)", arguments: [m.to, v])
                } else {
                    try d.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [m.to])
                }
            }
        }
    }

    /// Sold / Lost / Remove: nothing is deleted (rides stay, the service book still exports); the app stops connecting to it.
    static func retire(_ id: String, as status: GarageStatus, _ db: AppDatabase) {
        var r = registry(db).retire(id, as: status, atMs: nowMs())
        if r.activeId == id, let next = r.active(connectedId: nil) {
            // the next scooter in use takes over its settings
            swapSettings(from: id, to: next.id, db)
            onSwap?(id, next.id)
            r.activeId = next.id
            markActiveRow(next.id, db)
        } else if r.activeId == id {
            try? db.writer.write { d in try d.execute(sql: "UPDATE scooter SET forgottenAt = COALESCE(forgottenAt, ?) WHERE id = ?", arguments: [nowMs(), id]) }
        }
        save(r, db)
    }

    static func rename(_ id: String, _ name: String?, _ db: AppDatabase) { save(registry(db).renamed(id, to: name), db) }

    static func setBorrowing(_ id: String, _ on: Bool, _ db: AppDatabase) { save(registry(db).borrowing(id, on), db) }

    /// Peripheral ids the app connects to (in use, not sold / lost / removed)
    static func connectableIds(_ db: AppDatabase?) -> [String] { registry(db).inUse.map(\.id) }

    /// N11-2: the active scooter's id when its `scooter` row exists (a ride / charge may only reference a saved row)
    static func tagId(_ db: AppDatabase) -> String? {
        guard let id = activeId(db) else { return nil }
        let exists: Int = (try? db.writer.read { d -> Int in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM scooter WHERE id = ?", arguments: [id]) ?? 0
        }) ?? 0
        return exists > 0 ? id : nil
    }

    /// Rides on one scooter (the learning rule: no range / fault hints before ~10)
    static func rideCount(_ id: String, _ db: AppDatabase) -> Int {
        (try? db.writer.read { d -> Int in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM ride WHERE scooterId = ? AND kind = 'ride' AND endAt IS NOT NULL AND isSimulated = 0", arguments: [id]) ?? 0
        }) ?? 0
    }

    /// N11-2: "Just borrowing" is on for the scooter in use (no maintenance alerts, no tyre hint)
    static func activeIsBorrowed(_ db: AppDatabase?) -> Bool {
        let r = registry(db)
        return r.scooter(r.activeId)?.borrowing ?? false
    }

    /// Lock screen / charging card: the name only with 2+ scooters
    static func lockScreenName(_ db: AppDatabase?) -> String {
        let r = registry(db)
        return r.lockScreenName(activeId: r.activeId)
    }
}
