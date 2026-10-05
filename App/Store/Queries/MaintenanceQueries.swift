import Foundation
import GRDB

/// M3-06: `maintenance_item` (DATA_MODEL). Plain rows; the rules are in CorckieCore (`Maintenance`).
/// No CorckieCore import: App/Store is compiled into AppTests on its own. No schema change (migration v1 has the table).
struct MaintenanceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "maintenance_item"

    var id: String
    var name: String
    var intervalKm: Double?
    var intervalDays: Double?
    var lastDoneOdoKm: Double?
    /// epoch milliseconds
    var lastDoneAt: Int64?
    var notifiedAt: Int64?
}

struct MaintenanceQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    func all() throws -> [MaintenanceRecord] {
        try database.writer.read { db in try MaintenanceRecord.order(Column("rowid")).fetchAll(db) }
    }

    /// Insert the rows that do not exist yet (never overwrites an edited row).
    func insertMissing(_ rows: [MaintenanceRecord]) throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        try database.writer.write { db in
            for row in rows where try MaintenanceRecord.fetchOne(db, key: row.id) == nil { try row.insert(db) }
        }
    }

    func save(_ row: MaintenanceRecord) throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        try database.writer.write { db in try row.save(db) }
    }

    /// The scooter's odometer after the latest ride that has one (km), nil before any ride.
    func odometerKm() throws -> Double? {
        try database.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT odoEndKm FROM ride WHERE odoEndKm IS NOT NULL ORDER BY startAt DESC LIMIT 1")
        }
    }

    /// Notifications sent in the local day of `nowMs` that count against the 2 a day budget (Arrive-by and the
    /// Going-for-a-ride chime are outside it).
    func notificationsSentToday(nowMs: Int64, utcOffsetMin: Int) throws -> Int {
        let offset = Int64(utcOffsetMin) * 60_000
        let dayStart = ((nowMs + offset) / 86_400_000) * 86_400_000 - offset
        return try database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message_log WHERE channel = 'notification' AND sentAt >= ? AND sentAt < ?
                AND type NOT IN ('leave_by', 'going_for_a_ride')
                """, arguments: [dayStart, dayStart + 86_400_000]) ?? 0
        }
    }
}
