import Foundation
import GRDB

/// M3-02: the `charge` table (DATA_MODEL; migration v1, no schema change). Charges are derived from the rides
/// (rested % jumps between rides, CALC_SPEC M30), so the rows are rewritten as a whole each time the rides change.
/// Plain rows only; the rules are in CorckieCore (`ChargeDetector`). No CorckieCore import (App/Store is compiled into AppTests).
struct ChargeRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "charge"

    var id: String
    var scooterId: String?
    var afterRideId: String?
    var beforeRideId: String?
    var fromPct: Double?
    var toPct: Double?
    var fromV: Double?
    var toV: Double?
    /// epoch ms
    var windowStartAt: Int64?
    var windowEndAt: Int64?
    var inferredWhileAway: Bool = true
    var startedByShutdownFlag: Bool = false

    var chargedPct: Double { max(0, (toPct ?? 0) - (fromPct ?? 0)) }
}

struct ChargeQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// Newest first
    func all(limit: Int = 200) throws -> [ChargeRecord] {
        try database.writer.read { db in
            try ChargeRecord.order(Column("windowEndAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// Replaces every charge row with these (they are all derived from the rides). Returns true when anything changed.
    @discardableResult
    func replaceAll(_ rows: [ChargeRecord]) throws -> Bool {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        return try database.writer.write { db in
            let old = try ChargeRecord.fetchAll(db)
            if old.sorted(by: { $0.id < $1.id }) == rows.sorted(by: { $0.id < $1.id }) { return false }
            try db.execute(sql: "DELETE FROM charge")
            for r in rows { try r.insert(db) }
            return true
        }
    }
}
