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

    /// The ACTIVE scooter's odometer after its latest ride that has one (km), nil before any ride.
    /// Hotfix .07: only the active scooter's rides (the same rule as `BatteryDoor`, written out: no CorckieCore here). A scooter
    /// that sends no odometer (the G500) has none: it never borrows the G100's km.
    /// Hotfix .14 (N12-4, owner 24 Nov): a scooter that sends no odometer (the G500) counts its km from its OWN rides, so tyre and
    /// brake reminders and the service book keep counting. A scooter with an odometer keeps using it.
    func odometerKm() throws -> Double? {
        try database.writer.read { db in
            if let odo = try Double.fetchOne(db, sql: """
                SELECT odoEndKm FROM ride WHERE odoEndKm IS NOT NULL
                AND (scooterId IS NULL OR scooterId IN (SELECT id FROM scooter WHERE forgottenAt IS NULL))
                ORDER BY startAt DESC LIMIT 1
                """) { return odo }
            return try Self.rideKm(db)
        }
    }

    /// N12-4: the active scooter's km from its own finished real rides; nil when it has none (or no scooter is saved)
    static func rideKm(_ db: Database) throws -> Double? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COALESCE(SUM(distanceM), 0) AS m FROM ride
            WHERE endAt IS NOT NULL AND isSimulated = 0 AND kind IN ('ride', 'shortHop')
            AND scooterId IN (SELECT id FROM scooter WHERE forgottenAt IS NULL)
            """) else { return nil }
        let n: Int = row["n"]
        let m: Double = row["m"]
        return n > 0 ? m / 1000 : nil
    }

    /// N12-4: put a scooter's own item set in place (switching scooters)
    func replaceAll(_ rows: [MaintenanceRecord]) throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        try database.writer.write { db in
            try MaintenanceRecord.deleteAll(db)
            for r in rows { try r.insert(db) }
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
