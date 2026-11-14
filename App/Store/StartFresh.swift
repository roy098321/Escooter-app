import CorckieCore
import Foundation
import GRDB

/// D2 section 6 (A1 + A2 keep): "Start fresh" for a new scooter. What goes is decided by `DataMap`, not by a list of its own.
/// - Scooter and accuracy data always start over (a new pack, a new learning curve).
/// - Rider info (places, routes, ride times) is kept or cleared, the rider's choice. Kept rides stay tagged with the OLD scooter
///   (its `scooter` row is marked forgotten, not deleted), so battery math can skip them and times and routes still count.
/// - Logs and outside data (weather, holidays, fuel prices) stay; the backup holds the full picture.
/// The mandatory backup is a full copy of the database on the phone (`localBackup`), plus the Files-folder backup when one is set up.
enum StartFresh {
    static let startedKey = "fresh.startedAtMs"
    static let keptRiderKey = "fresh.keptRider"

    /// Tables cleared in every mode (all except the scooter row, which is handled per mode).
    static var alwaysCleared: [String] {
        (DataMap.wholeTables(.scooter).filter { $0 != "scooter" } + DataMap.wholeTables(.accuracy)).sorted()
    }

    /// Rider tables cleared only when the rider does not keep rider info (cascades take the rides' samples, stops, chunks and notes).
    static let riderCleared = ["ride", "place", "route", "climb", "insight", "week_summary", "price_history", "setting"]

    /// A full copy of the database next to it, on the phone only (P-9: it holds places). Throws when it cannot be written, which stops the reset.
    @discardableResult
    static func localBackup(_ db: AppDatabase, nowMs: Int64) throws -> URL {
        let folder = db.url.deletingLastPathComponent().appendingPathComponent("StartFreshBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("corckie-before-fresh-\(nowMs).sqlite")
        try db.writeSnapshot(to: target)
        guard FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteUnknown) }
        return target
    }

    /// Tables brought back by A2, in a parents-first order (foreign keys are also deferred inside the transaction).
    static let bringBackTables = ["place", "route", "variant", "choice_point", "choice_option", "climb", "elevation_point", "ride", "stop",
                                  "ride_sample", "ride_option", "ride_climb", "ride_note", "insight", "week_summary", "price_history"]
    static let broughtBackKey = "fresh.broughtBackAtMs"

    /// The newest "before start fresh" copy on this phone, if any.
    static func latestBackup(_ db: AppDatabase) -> URL? {
        let folder = db.url.deletingLastPathComponent().appendingPathComponent("StartFreshBackups", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("corckie-before-fresh-") }.max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A2: "Bring rider info back". Copies the rider's places, routes and rides from the backup into the current database without
    /// replacing anything that is already there. Brought-back rides belong to the OLD scooter (its row is added, marked forgotten),
    /// so the battery door keeps them out of the new scooter's battery math. All or nothing. Returns how many rides came back.
    @discardableResult
    static func bringRiderInfoBack(_ db: AppDatabase, from backup: URL, nowMs: Int64) throws -> Int {
        guard !db.isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        var brought = 0
        try db.writer.writeWithoutTransaction { d in
            try d.execute(sql: "ATTACH DATABASE ? AS bk", arguments: [backup.path])
            defer { try? d.execute(sql: "DETACH DATABASE bk") }
            try d.inTransaction {
                try d.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try d.execute(sql: "CREATE TEMP TABLE bring_ids AS SELECT id FROM bk.ride WHERE id NOT IN (SELECT id FROM main.ride)")
                brought = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM bring_ids") ?? 0
                // the old scooter rows come along, forgotten (a row that already exists is never touched)
                let newScooters = try String.fetchAll(d, sql: "SELECT id FROM bk.scooter WHERE id NOT IN (SELECT id FROM main.scooter)")
                try d.execute(sql: "INSERT OR IGNORE INTO main.scooter SELECT * FROM bk.scooter WHERE id IN (SELECT id FROM bk.scooter WHERE id NOT IN (SELECT id FROM main.scooter))")
                for id in newScooters {
                    try d.execute(sql: "UPDATE main.scooter SET forgottenAt = COALESCE(forgottenAt, ?) WHERE id = ?", arguments: [nowMs, id])
                }
                for table in bringBackTables {
                    try d.execute(sql: "INSERT OR IGNORE INTO main.\"\(table)\" SELECT * FROM bk.\"\(table)\"")
                }
                let untagged = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM main.ride WHERE scooterId IS NULL AND id IN (SELECT id FROM bring_ids)") ?? 0
                if untagged > 0 {
                    try d.execute(sql: "INSERT OR IGNORE INTO main.scooter (id, name, firstSeenAt, forgottenAt) VALUES ('previous', 'Previous scooter', 0, ?)", arguments: [nowMs])
                    try d.execute(sql: "UPDATE main.ride SET scooterId = 'previous' WHERE scooterId IS NULL AND id IN (SELECT id FROM bring_ids)")
                }
                // rider settings come back too, never the scooter's and never this tool's own bookkeeping
                let skip = DataMap.scooterSettingKeys.map { "'\($0)'" }.joined(separator: ",")
                try d.execute(sql: "INSERT OR IGNORE INTO main.setting SELECT * FROM bk.setting WHERE key NOT IN (\(skip)) AND key NOT LIKE 'fresh.%'")
                try d.execute(sql: "DROP TABLE bring_ids")
                try d.execute(sql: "INSERT OR REPLACE INTO setting (key, json) VALUES (?, ?)", arguments: [broughtBackKey, String(nowMs)])
                return .commit
            }
        }
        return brought
    }

    /// The reset itself, in one transaction: all or nothing.
    static func reset(_ db: AppDatabase, keepRider: Bool, nowMs: Int64) throws {
        guard !db.isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        try db.writer.write { d in
            for table in alwaysCleared { try d.execute(sql: "DELETE FROM \"\(table)\"") }
            if keepRider {
                // the old scooter's rides stay, tagged by its (now forgotten) row: the battery door skips them from now on
                var oldId = try String.fetchOne(d, sql: "SELECT id FROM scooter ORDER BY firstSeenAt DESC LIMIT 1")
                if oldId == nil {
                    oldId = "previous"
                    try d.execute(sql: "INSERT INTO scooter (id, name, firstSeenAt) VALUES ('previous', 'Previous scooter', 0)")
                }
                try d.execute(sql: "UPDATE ride SET scooterId = ? WHERE scooterId IS NULL", arguments: [oldId])
                try d.execute(sql: "UPDATE scooter SET forgottenAt = COALESCE(forgottenAt, ?)", arguments: [nowMs])
                for key in DataMap.scooterSettingKeys { try d.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key]) }
            } else {
                for table in riderCleared { try d.execute(sql: "DELETE FROM \"\(table)\"") }
                try d.execute(sql: "DELETE FROM scooter")
            }
            try d.execute(sql: "INSERT OR REPLACE INTO setting (key, json) VALUES (?, ?)", arguments: [startedKey, String(nowMs)])
            try d.execute(sql: "INSERT OR REPLACE INTO setting (key, json) VALUES (?, ?)", arguments: [keptRiderKey, keepRider ? "1" : "0"])
        }
    }
}
