import CorckieCore
import Foundation
import GRDB

/// M4-01: the outside-data tables (migration v1, no schema change) behind Core's `OutsideStore`: `weather_hour`,
/// `elevation_point`, `holiday`, and `setting` for the once-a-day retry marks. Plus the two reads the refresh needs
/// from the ride tables (a ride's first GPS fix, a ride's cells).
struct OutsideQueries: OutsideStore {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    private func guardWritable() throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
    }

    // MARK: Weather

    func weather(cell: String, from: Int64, to: Int64, kind: WeatherKind) throws -> [WeatherRow] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT cellKey, hourAt, source, kind, windKmh, windFromDeg, gustKmh, precipMm, airTempC, fetchedAt
                FROM weather_hour WHERE cellKey = ? AND kind = ? AND hourAt >= ? AND hourAt <= ? ORDER BY hourAt
                """, arguments: [cell, kind.rawValue, from, to]).map { row in
                WeatherRow(cellKey: row["cellKey"], hourAt: row["hourAt"], source: (row["source"] as String?) ?? "", kind: kind,
                           windKmh: (row["windKmh"] as Double?) ?? 0, windFromDeg: row["windFromDeg"], gustKmh: row["gustKmh"],
                           precipMm: row["precipMm"], airTempC: row["airTempC"], fetchedAt: (row["fetchedAt"] as Int64?) ?? 0)
            }
        }
    }

    func save(weather: [WeatherRow]) throws {
        try guardWritable()
        try database.writer.write { db in
            for r in weather {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO weather_hour
                    (cellKey, hourAt, source, kind, windKmh, windFromDeg, gustKmh, precipMm, airTempC, fetchedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [r.cellKey, r.hourAt, r.source, r.kind.rawValue, r.windKmh, r.windFromDeg, r.gustKmh,
                                     r.precipMm, r.airTempC, r.fetchedAt])
            }
        }
    }

    func pruneWeather(before: Int64) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM weather_hour WHERE hourAt < ?", arguments: [before])
        }
    }

    // MARK: Elevation

    func elevation(cell: String) throws -> Double? {
        try database.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT altM FROM elevation_point WHERE cellKey = ?", arguments: [cell])
        }
    }

    func save(elevations: [String: Double], source: String) throws {
        try guardWritable()
        try database.writer.write { db in
            for (cell, alt) in elevations {
                try db.execute(sql: "INSERT OR REPLACE INTO elevation_point (cellKey, altM, source) VALUES (?, ?, ?)",
                               arguments: [cell, alt, source])
            }
        }
    }

    // MARK: Holidays

    func holidays(year: Int) throws -> [StoredHoliday] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT date, kind, name, source FROM holiday WHERE date LIKE ? ORDER BY date, name",
                             arguments: ["\(year)-%"]).map { row in
                let kind: String = row["kind"]
                return StoredHoliday(holiday: Holiday(date: row["date"], name: row["name"], kind: kind == "eve" ? .eve : .holiday),
                                     source: (row["source"] as String?) ?? "")
            }
        }
    }

    func replaceHolidays(year: Int, with days: [Holiday], source: String) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM holiday WHERE date LIKE ?", arguments: ["\(year)-%"])
            for h in days {
                try db.execute(sql: "INSERT OR REPLACE INTO holiday (date, kind, name, source) VALUES (?, ?, ?, ?)",
                               arguments: [h.date, h.kind.rawValue, h.name, source])
            }
        }
    }

    // MARK: Retry marks (setting table, key outside.try.<key>)

    func lastAttempt(_ key: String) throws -> Int64? {
        try database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT CAST(json AS INTEGER) FROM setting WHERE key = ?", arguments: ["outside.try." + key])
        }
    }

    func markAttempt(_ key: String, at: Int64) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO setting (key, json) VALUES (?, ?)", arguments: ["outside.try." + key, String(at)])
        }
    }

    // MARK: Reads for the refresh

    /// The newest rides that could need weather: real (not simulated), ended, with the first GPS fix when there is one.
    func backfillRides(limit: Int) throws -> [BackfillRide] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, startAt, endAt FROM ride
                WHERE kind = 'ride' AND status IN ('ended', 'recovered') AND isSimulated = 0 AND endAt IS NOT NULL
                ORDER BY startAt DESC LIMIT ?
                """, arguments: [limit])
            return try rows.map { row in
                let id: String = row["id"]
                let fix = try Row.fetchOne(db, sql: "SELECT lat, lon FROM ride_sample WHERE rideId = ? AND lat IS NOT NULL AND lon IS NOT NULL ORDER BY t LIMIT 1",
                                           arguments: [id])
                var lat: Double?
                var lon: Double?
                if let fix {
                    lat = fix["lat"]
                    lon = fix["lon"]
                }
                return BackfillRide(id: id, startAt: row["startAt"], endAt: row["endAt"], lat: lat, lon: lon)
            }
        }
    }

    /// The ~1 km cells a ride passed through, in order, each once.
    func rideCells(rideId: String) throws -> [String] {
        try database.writer.read { db in
            var seen = Set<String>()
            var out: [String] = []
            let cursor = try Row.fetchCursor(db, sql: "SELECT lat, lon FROM ride_sample WHERE rideId = ? AND lat IS NOT NULL AND lon IS NOT NULL ORDER BY t",
                                             arguments: [rideId])
            while let row = try cursor.next() {
                let lat: Double = row["lat"], lon: Double = row["lon"]
                let key = GeoCell.key(lat: lat, lon: lon)
                if seen.insert(key).inserted { out.append(key) }
            }
            return out
        }
    }

    struct Counts: Equatable {
        var weatherHours = 0
        var forecastHours = 0
        var historyHours = 0
        var elevationCells = 0
        var holidays = 0
        var holidaysOffline = 0
    }

    func counts() throws -> Counts {
        try database.writer.read { db in
            var c = Counts()
            c.forecastHours = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weather_hour WHERE kind = 'forecast'") ?? 0
            c.historyHours = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weather_hour WHERE kind = 'history'") ?? 0
            c.weatherHours = c.forecastHours + c.historyHours
            c.elevationCells = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM elevation_point") ?? 0
            c.holidays = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM holiday") ?? 0
            c.holidaysOffline = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM holiday WHERE source = 'offline'") ?? 0
            return c
        }
    }
}
