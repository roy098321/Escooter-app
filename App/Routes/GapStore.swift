import CorckieCore
import Foundation
import GRDB

/// B35: riding that was not recorded, found by the odometer. Uses the table `untracked_distance` that exists since the first schema
/// (id, scooterId, fromOdoKm, toOdoKm, detectedAt), so no migration. Compiled into AppTests too: database only, no sensors.
struct UntrackedGap: Equatable, Identifiable {
    var id: String
    var fromKm: Double
    var toKm: Double
    var detectedAtMs: Int64
    var km: Double { toKm - fromKm }
}

enum GapStore {
    /// The odometer at the end of the newest finished real ride; nil when unknown (then there is no verdict, never a guess)
    static func lastRideEndOdoKm(_ database: AppDatabase) -> Double? {
        let value: Double?? = try? database.writer.read { (db: Database) -> Double? in
            guard let row = try Row.fetchOne(db, sql: "SELECT odoEndKm FROM ride WHERE endAt IS NOT NULL AND isSimulated = 0 ORDER BY endAt DESC LIMIT 1") else { return nil }
            let odo: Double? = row["odoEndKm"]
            return odo
        }
        return value ?? nil
    }

    static func lastGapToKm(_ database: AppDatabase) -> Double? {
        let value: Double?? = try? database.writer.read { (db: Database) -> Double? in
            try Double.fetchOne(db, sql: "SELECT MAX(toOdoKm) FROM untracked_distance")
        }
        return value ?? nil
    }

    /// Notes a gap when the odometer shows one; returns it. Writes nothing on a read-only database.
    @discardableResult
    static func detect(_ database: AppDatabase, connectOdoKm: Double?, nowMs: Int64) -> UntrackedGap? {
        guard !database.isReadOnly, let now = connectOdoKm,
              let end = lastRideEndOdoKm(database),
              OdometerGap.km(connectKm: now, lastRideEndKm: end, lastGapToKm: lastGapToKm(database)) != nil else { return nil }
        let from = max(end, lastGapToKm(database) ?? 0)
        let gap = UntrackedGap(id: UUID().uuidString, fromKm: from, toKm: now, detectedAtMs: nowMs)
        try? database.writer.write { db in
            try db.execute(sql: "INSERT INTO untracked_distance (id, scooterId, fromOdoKm, toOdoKm, detectedAt) VALUES (?, NULL, ?, ?, ?)",
                           arguments: [gap.id, gap.fromKm, gap.toKm, gap.detectedAtMs])
        }
        return gap
    }

    /// newest first
    static func all(_ database: AppDatabase) -> [UntrackedGap] {
        let rows = (try? database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, fromOdoKm, toOdoKm, detectedAt FROM untracked_distance WHERE fromOdoKm IS NOT NULL AND toOdoKm IS NOT NULL ORDER BY detectedAt DESC")
        }) ?? []
        return rows.map { r in
            let id: String = r["id"]
            let from: Double = r["fromOdoKm"]
            let to: Double = r["toOdoKm"]
            let at: Int64? = r["detectedAt"]
            return UntrackedGap(id: id, fromKm: from, toKm: to, detectedAtMs: at ?? 0)
        }
    }
}
