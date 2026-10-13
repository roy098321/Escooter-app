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

    /// The start of the oldest real ride (the first week is partial, S12)
    func firstRideMs() -> Int64? {
        try? database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(startAt) FROM ride WHERE endAt IS NOT NULL AND kind IN ('ride', 'shortHop') AND isSimulated = 0")
        }
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

    /// F-01: every real ended ride and short hop with its km and battery used (the shown value when there is one), plus the odometer
    /// at the first ride's start and the newest odometer reading.
    func overallRows() throws -> (rides: [(startAt: Int64, offsetMin: Int, km: Double, usedPct: Double?)], firstOdoKm: Double?, latestOdoKm: Double?) {
        try database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT startAt, utcOffsetMin, distanceM, COALESCE(usedPctShown, usedPct) AS used, odoStartKm, odoEndKm FROM ride
                WHERE endAt IS NOT NULL AND kind IN ('ride', 'shortHop') AND isSimulated = 0 ORDER BY startAt
                """)
            var rides: [(startAt: Int64, offsetMin: Int, km: Double, usedPct: Double?)] = []
            var firstOdo: Double?
            var latest: Double?
            for r in rows {
                let offset: Int? = r["utcOffsetMin"]
                let distance: Double? = r["distanceM"]
                let used: Double? = r["used"]
                rides.append((r["startAt"], offset ?? 0, (distance ?? 0) / 1000, used))
                let start: Double? = r["odoStartKm"]
                let end: Double? = r["odoEndKm"]
                if firstOdo == nil { firstOdo = start }
                if let end { latest = max(latest ?? end, end) }
            }
            return (rides, firstOdo, latest)
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
