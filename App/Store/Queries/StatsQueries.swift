import CorckieCore
import Foundation
import GRDB

/// M4-07: what the Stats tab reads: ended real rides and short hops (no simulated, no discarded), the day-off holidays, the fuel
/// price by month and the two price settings (electricity ILS / kWh, car L / 100 km). No schema change (migration v1).
struct StatsQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    func rides(from: Int64, to: Int64) throws -> [StatsRide] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startAt, utcOffsetMin, kind, distanceM, totalS, usedPct FROM ride
                WHERE endAt IS NOT NULL AND kind IN ('ride', 'shortHop') AND isSimulated = 0 AND startAt >= ? AND startAt < ? ORDER BY startAt
                """, arguments: [from, to]).map { r -> StatsRide in
                let offset: Int? = r["utcOffsetMin"]
                let distance: Double? = r["distanceM"]
                let total: Double? = r["totalS"]
                let used: Double? = r["usedPct"]
                return StatsRide(startAt: r["startAt"], utcOffsetMin: offset ?? 0, kind: r["kind"], distanceM: distance ?? 0, totalS: total ?? 0, usedPct: used)
            }
        }
    }

    /// Local dates ("yyyy-MM-dd") of the holidays that count as a day off
    func dayOffDates() throws -> Set<String> {
        let years = try database.writer.read { db in try Row.fetchAll(db, sql: "SELECT date, kind, name FROM holiday") }
        var out: Set<String> = []
        for r in years {
            let kind: String = r["kind"]
            let h = Holiday(date: r["date"], name: r["name"], kind: kind == "eve" ? .eve : .holiday)
            if h.isDayOff { out.insert(h.date) }
        }
        return out
    }

    func fuelPricesByMonth() throws -> [String: Double] {
        try database.writer.read { db in
            var out: [String: Double] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT month, priceIls FROM fuel_price") {
                let month: String = r["month"]
                let price: Double = r["priceIls"]
                out[month] = price
            }
            return out
        }
    }

    // MARK: Price settings

    static let electricityKey = "stats.electricityIlsPerKwh"
    static let fuelUseKey = "stats.fuelLPer100km"

    func number(_ key: String) -> Double? {
        guard let s = try? RideQueries(database).setting(key: key) else { return nil }
        return Double(s)
    }

    func setNumber(_ key: String, _ value: Double) throws {
        try RideQueries(database).setSetting(key: key, json: String(value))
    }
}
