import Foundation
import GRDB

/// M4-05: the ride columns the smart prompt and the Loaded tag write (`loadLevel`, `loadKg`, `promptAnswer`, `excludedFromUsual`),
/// and the tyre reminder made due. Plain SQL; the rules are in CorckieCore (`SmartPrompt`). No schema change (migration v1).
/// No CorckieCore import: App/Store is compiled into AppTests on its own.
struct SmartPromptQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    private func guardWritable() throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
    }

    struct RideAnswer: Equatable {
        var loadLevel: String?
        var loadKg: Double?
        var promptAnswer: String?
        var excluded: Bool
    }

    func rideAnswer(_ rideId: String) throws -> RideAnswer? {
        try database.writer.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT loadLevel, loadKg, promptAnswer, excludedFromUsual FROM ride WHERE id = ?", arguments: [rideId]) else { return nil }
            return RideAnswer(loadLevel: r["loadLevel"], loadKg: r["loadKg"], promptAnswer: r["promptAnswer"], excluded: r["excludedFromUsual"])
        }
    }

    /// The Loaded tag: level and kg (None 0, Light 5, Heavy 15, or an exact number)
    func setLoad(rideId: String, level: String, kg: Double) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE ride SET loadLevel = ?, loadKg = ? WHERE id = ?", arguments: [level, kg, rideId])
        }
    }

    /// An answer to the prompt: stored text, and the ride left out of the usual ranges when asked
    func setAnswer(rideId: String, answer: String, excluded: Bool) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE ride SET promptAnswer = ?, excludedFromUsual = CASE WHEN ? THEN 1 ELSE excludedFromUsual END WHERE id = ?",
                           arguments: [answer, excluded, rideId])
        }
    }

    /// Tyres felt soft: the tyre reminder becomes due (counting from before the interval), and is sent again
    func makeTyresDue(odometerKm: Double?, nowMs: Int64) throws {
        try guardWritable()
        try database.writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT intervalKm, intervalDays FROM maintenance_item WHERE id = 'tyres'") else { return }
            let km: Double? = row["intervalKm"]
            let days: Double? = row["intervalDays"]
            let lastKm: Double? = (odometerKm != nil && km != nil) ? odometerKm! - km! - 1 : nil
            let lastAt: Int64? = days.map { nowMs - Int64(($0 + 1) * 86_400_000) }
            try db.execute(sql: "UPDATE maintenance_item SET lastDoneOdoKm = COALESCE(?, lastDoneOdoKm), lastDoneAt = COALESCE(?, lastDoneAt), notifiedAt = NULL WHERE id = 'tyres'",
                           arguments: [lastKm, lastAt])
        }
    }

    /// Heat inputs of the route's other rides (rise, distance, air temperature), real rides only, not left out
    func heatRides(routeId: String, excluding rideId: String, simulated: Bool) throws -> [(riseC: Double?, distanceM: Double?, airTempC: Double?)] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT tempRiseC, distanceM, airTempC FROM ride WHERE routeId = ? AND id != ? AND kind = 'ride' AND excludedFromUsual = 0
                AND isSimulated = ? AND endAt IS NOT NULL ORDER BY startAt DESC LIMIT 40
                """, arguments: [routeId, rideId, simulated]).map { r -> (riseC: Double?, distanceM: Double?, airTempC: Double?) in
                let rise: Double? = r["tempRiseC"]
                let dist: Double? = r["distanceM"]
                let air: Double? = r["airTempC"]
                return (rise, dist, air)
            }
        }
    }
}
