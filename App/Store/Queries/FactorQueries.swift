import CorckieCore
import Foundation
import GRDB

/// M4-02: the ride's factor columns (`headwindKmh`, `windLevel`, `wet`, `rushHour`, `dayType`, `airTempC`, `holidayWeek`,
/// migration v1) and the `factor_effect` cache (no schema change). Rules are in Core (`RideWeatherCalc`, `DayContextCalc`,
/// `FactorEngine`).
///
/// `factor_effect` encoding: one row per factor level, scope, route and quantity. `level` = "<level>/<quantity>"
/// ("head/time", "perKg/used"); `scope` = route / pooled; `timeEffectS` or `usedEffectPct` holds the effect only when the
/// gate is passed (nothing is shown before its gate); `confidence` = 0...1 when passed, else the gate code
/// (-1 not enough rides, -2 inside the noise, -3 not confirmed, -4 combined, `FactorGate.code`).
struct FactorInputRow: Equatable {
    var id: String
    var routeId: String?
    var startAt: Int64
    var endAt: Int64?
    var utcOffsetMin: Int?
    var kind: String
    var isSimulated: Bool
    var distanceM: Double?
    var totalS: Double?
    var usedPct: Double?
    var gapScooterS: Double?
    var headwindKmh: Double?
    var windLevel: String?
    var wet: String?
    var wetOverride: String?
    var rushHour: Bool?
    var dayType: String?
    var airTempC: Double?
    var holidayWeek: Bool?
    var loadKg: Double?
    var promptAnswer: String?
    var elevGainM: Double?
    var excludedFromUsual: Bool
    var hasGps: Bool?
}

struct FactorQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    private func guardWritable() throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
    }

    private static let columns = """
        id, routeId, startAt, endAt, utcOffsetMin, kind, isSimulated, distanceM, totalS, usedPct, gapScooterS, headwindKmh, windLevel,
        wet, wetOverride, rushHour, dayType, airTempC, holidayWeek, loadKg, promptAnswer, elevGainM, excludedFromUsual, hasGps
        """

    private static func decode(_ row: Row) -> FactorInputRow {
        FactorInputRow(id: row["id"], routeId: row["routeId"], startAt: row["startAt"], endAt: row["endAt"], utcOffsetMin: row["utcOffsetMin"],
                       kind: row["kind"], isSimulated: row["isSimulated"], distanceM: row["distanceM"], totalS: row["totalS"],
                       usedPct: row["usedPct"], gapScooterS: row["gapScooterS"], headwindKmh: row["headwindKmh"], windLevel: row["windLevel"],
                       wet: row["wet"], wetOverride: row["wetOverride"], rushHour: row["rushHour"], dayType: row["dayType"],
                       airTempC: row["airTempC"], holidayWeek: row["holidayWeek"], loadKg: row["loadKg"], promptAnswer: row["promptAnswer"],
                       elevGainM: row["elevGainM"], excludedFromUsual: row["excludedFromUsual"], hasGps: row["hasGps"])
    }

    /// Every finished ride (not a discarded piece), newest first.
    func inputs() throws -> [FactorInputRow] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.columns) FROM ride WHERE kind != 'discarded' AND status != 'recording' ORDER BY startAt DESC")
                .map(Self.decode)
        }
    }

    func input(rideId: String) throws -> FactorInputRow? {
        try database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM ride WHERE id = ?", arguments: [rideId]).map(Self.decode)
        }
    }

    /// Rides whose columns are not filled yet: no day type, or no weather although they have GPS. Newest first.
    func pending(limit: Int) throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM ride WHERE kind != 'discarded' AND status != 'recording' AND endAt IS NOT NULL
                  AND (dayType IS NULL OR (windLevel IS NULL AND wet IS NULL AND hasGps = 1))
                ORDER BY startAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    /// The ride's GPS fixes (ms from the start).
    func fixes(rideId: String) throws -> [FactorFix] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT t, lat, lon, hAccM FROM ride_sample WHERE rideId = ? AND lat IS NOT NULL AND lon IS NOT NULL ORDER BY t",
                             arguments: [rideId]).map { row in
                FactorFix(t: row["t"], lat: row["lat"], lon: row["lon"], hAccM: row["hAccM"])
            }
        }
    }

    /// Writes the day columns always, and the weather columns only when the weather is there (pattern W keeps them nil).
    func setColumns(rideId: String, weather: RideWeather, day: DayContext) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE ride SET dayType = ?, rushHour = ?, holidayWeek = ? WHERE id = ?",
                           arguments: [day.dayType, day.rushHour, day.holidayWeek, rideId])
            if !weather.isMissing {
                try db.execute(sql: "UPDATE ride SET headwindKmh = ?, windLevel = ?, wet = ?, airTempC = ? WHERE id = ?",
                               arguments: [weather.headwindKmh, weather.windLevel, weather.wet, weather.airTempC, rideId])
            }
        }
    }

    // MARK: factor_effect

    func replaceEffects(_ effects: [FactorEffect], computedAt: Int64) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM factor_effect")
            for e in effects {
                try db.execute(sql: """
                    INSERT INTO factor_effect (factorId, scope, routeId, level, timeEffectS, usedEffectPct, n, nWithout, confidence, computedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [e.factorId, e.scope.rawValue, e.routeId, e.level + "/" + e.quantity.rawValue, e.timeEffectS, e.usedEffectPct,
                                     e.n, e.nWithout, e.passesGate ? e.confidence : e.gate.code, computedAt])
            }
        }
    }

    func effects(scope: FactorScope? = nil, routeId: String? = nil) throws -> [FactorEffect] {
        try database.writer.read { db in
            var sql = "SELECT factorId, scope, routeId, level, timeEffectS, usedEffectPct, n, nWithout, confidence FROM factor_effect WHERE 1 = 1"
            var args: [DatabaseValueConvertible?] = []
            if let scope {
                sql += " AND scope = ?"
                args.append(scope.rawValue)
            }
            if let routeId {
                sql += " AND routeId = ?"
                args.append(routeId)
            }
            sql += " ORDER BY id"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).compactMap { row -> FactorEffect? in
                let stored: String = row["level"]
                let parts = stored.split(separator: "/").map(String.init)
                guard parts.count == 2, let q = FactorQuantity(rawValue: parts[1]),
                      let sc = FactorScope(rawValue: (row["scope"] as String?) ?? "") else { return nil }
                let confidence: Double? = row["confidence"]
                let gate = FactorGate.from(confidence: confidence)
                let effect: Double? = q == .time ? row["timeEffectS"] : row["usedEffectPct"]
                return FactorEffect(factorId: row["factorId"], level: parts[0], scope: sc, routeId: row["routeId"], quantity: q,
                                    effect: gate == .passed ? effect : nil, n: (row["n"] as Int?) ?? 0, nWithout: (row["nWithout"] as Int?) ?? 0,
                                    confidence: confidence ?? FactorGate.notEnoughRides.code, gate: gate)
            }
        }
    }

    func effectCount() throws -> (rows: Int, passed: Int) {
        try database.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM factor_effect") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM factor_effect WHERE confidence > 0") ?? 0)
        }
    }
}
