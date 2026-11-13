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
