import Foundation
import GRDB

/// M3-01: the `calibration` row (DATA_MODEL; migration v1, no schema change) and the ride columns the calibration reads.
/// Plain rows only; the rules are in CorckieCore (`BatteryCalibrator`). No CorckieCore import: App/Store is compiled into
/// AppTests on its own.
struct CalibrationRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calibration"

    var id: String
    var scooterId: String?
    /// epoch ms
    var startedAt: Int64?
    /// learning / active / replaced (DATA_MODEL)
    var status: String = "learning"
    /// M8 k = V × I Wh per 1% ÷ (pack Wh ÷ 100)
    var factor: Double?
    var ridesUsed: Int = 0
    var packAh: Double?
}

/// One ride as the calibration reads it (the `ride` row + its longest scooter gap + its last live battery %).
struct CalibrationInputRow: Equatable {
    var id: String
    var startAt: Int64
    var endAt: Int64?
    var kind: String
    var isSimulated: Bool
    var energyWhRaw: Double?
    var startRestPct: Double?
    var endRestPct: Double?
    var distanceM: Double?
    var gapScooterS: Double?
    /// ms, from the `gap` table (nil without gap rows)
    var longestGapMs: Int64?
    var lastLivePct: Int?
    var usedPct: Double?
    var usedPctMethod: String?
    var energyWhCal: Double?
}

struct CalibrationQueries {
    /// One calibration row per install for now (one scooter); Recalibrate (S7) adds rows later
    static let mainId = "battery"

    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// The row in use: the newest one that is not replaced
    func current() throws -> CalibrationRecord? {
        try database.writer.read { db in
            try CalibrationRecord.filter(Column("status") != "replaced").order(Column("startedAt").desc).fetchOne(db)
        }
    }

    func save(_ row: CalibrationRecord) throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        try database.writer.write { db in try row.save(db) }
    }

    /// Every ride that is not a discarded piece, newest first, with what the calibration needs.
    func inputs(limit: Int = 500) throws -> [CalibrationInputRow] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.id, r.startAt, r.endAt, r.kind, r.isSimulated, r.energyWhRaw, r.startRestPct, r.endRestPct, r.distanceM,
                       r.gapScooterS, r.usedPct, r.usedPctMethod, r.energyWhCal,
                       (SELECT MAX(COALESCE(g.endT, g.startT) - g.startT) FROM gap g WHERE g.rideId = r.id AND g.kind = 'scooter') AS longestGapMs,
                       (SELECT s.batteryPct FROM ride_sample s WHERE s.rideId = r.id AND s.batteryPct IS NOT NULL ORDER BY s.t DESC LIMIT 1) AS lastLivePct
                FROM ride r WHERE r.kind != 'discarded' AND r.status != 'recording'
                ORDER BY r.startAt DESC LIMIT ?
                """, arguments: [limit])
            return rows.map { row in
                CalibrationInputRow(id: row["id"], startAt: row["startAt"], endAt: row["endAt"], kind: row["kind"],
                                    isSimulated: row["isSimulated"], energyWhRaw: row["energyWhRaw"], startRestPct: row["startRestPct"],
                                    endRestPct: row["endRestPct"], distanceM: row["distanceM"], gapScooterS: row["gapScooterS"],
                                    longestGapMs: row["longestGapMs"], lastLivePct: row["lastLivePct"], usedPct: row["usedPct"],
                                    usedPctMethod: row["usedPctMethod"], energyWhCal: row["energyWhCal"])
            }
        }
    }

    /// Writes battery used for rides whose value changed (M8 re-run); returns how many rows changed.
    @discardableResult
    func setUsed(_ changes: [(id: String, usedPct: Double?, method: String?, energyWhCal: Double?)]) throws -> Int {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        guard !changes.isEmpty else { return 0 }
        return try database.writer.write { db in
            for c in changes {
                try db.execute(sql: "UPDATE ride SET usedPct = ?, usedPctMethod = ?, energyWhCal = ? WHERE id = ?",
                               arguments: [c.usedPct, c.method, c.energyWhCal, c.id])
            }
            return changes.count
        }
    }
}
