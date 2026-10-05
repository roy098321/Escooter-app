import CorckieCore
import Foundation

// M4-05 / M4-06: more made-up rides in a temporary database for the checks u34 / u35 and the Developer → Insights buttons
// (mp1, mh1). Same ocean commute as `InsightSeed.windyWeek`; never on the real database.

extension InsightSeed {
    /// 12 rides on "Seed commute", the last one clearly hotter (peak 93 °C, +68 °C, air 33 °C; the others +30 °C at 27 °C), then the
    /// after-ride insights of that ride: the Peak card and the hot-day card.
    @discardableResult
    static func hotRide(_ database: AppDatabase) throws -> Result {
        let seeded = try windyWeek(database, rides: 12)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE ride SET tempStartC = 25, tempPeakC = 55, tempRiseC = 30, airTempC = 27 WHERE routeId = ?", arguments: [routeId])
            try db.execute(sql: "UPDATE ride SET tempPeakC = 93, tempRiseC = 68, airTempC = 33 WHERE id = ?", arguments: [seeded.lastRideId])
        }
        var result = seeded
        result.report = try InsightRunner.afterRide(database, rideId: seeded.lastRideId, nowMs: seeded.nowMs + 60_000)
        return result
    }

    /// 12 rides, the last one using 8 points more battery than the others; the smart prompt can be asked for it.
    @discardableResult
    static func promptRide(_ database: AppDatabase) throws -> Result {
        let seeded = try windyWeek(database, rides: 12)
        let usual = try database.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT AVG(usedPct) FROM ride WHERE routeId = ? AND id != ?", arguments: [routeId, seeded.lastRideId]) ?? 9
        }
        try database.writer.write { db in
            // the wind of the seed week is not the reason: dry, calm
            try db.execute(sql: "UPDATE ride SET usedPct = ?, headwindKmh = 0, windLevel = 'light' WHERE id = ?", arguments: [usual + 8, seeded.lastRideId])
        }
        return seeded
    }
}
