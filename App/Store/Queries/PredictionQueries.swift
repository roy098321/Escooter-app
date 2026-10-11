import Foundation
import GRDB

/// T-00 part 2: the prediction log (`prediction`) and the shadow-threshold results (`shadow_result`).
/// No CorckieCore import: App/Store is compiled into AppTests on its own. The Core rules (matching, errors) are used by
/// `App/Recorder/FieldKitService.swift`.
struct PredictionRecord: Equatable {
    var id: Int64
    var kind: String
    var routeId: String?
    var madeAt: Int64
    var predicted: Double
    var aux: Double?
    var rideId: String?
    var actual: Double?
}

struct ShadowStored: Equatable {
    var startAt: Int64
    var rule: String
    var variant: String
    var decision: String
    var differs: Bool
    var isStandard: Bool
}

/// What a closed ride gives the log, read straight from the ride row (columns the ride record does not carry).
struct PredictionRideFacts: Equatable {
    var id: String
    var routeId: String?
    var startAt: Int64
    var endAt: Int64?
    var lastMoveAt: Int64?
    var totalS: Double?
    var distanceM: Double?
    var usedPct: Double?
    var startRestPct: Double?
    var endRestPct: Double?
    var energyWhRaw: Double?
    var kind: String
    var status: String
    var isSimulated: Bool
}

/// Ride-level facts for the scenario list (real, ended rides).
struct ScenarioRow: Equatable {
    var id: String
    var startAt: Int64
    var endAt: Int64
    var utcOffsetMin: Int
    var totalS: Double
    var distanceM: Double
    var startPct: Double?
    var wet: String?
    var gapGpsS: Double
    var hasGps: Bool
    var loadKg: Double?
    var loadLevel: String?
    var firstOnItsRoute: Bool
    var endReason: String?
}

struct PredictionQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// Same estimate shown again within this long is not stored twice
    static let dedupeMs: Int64 = 10 * 60_000

    private func guardWritable() throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
    }

    // MARK: Prediction log

    /// Stores what was shown. Skipped when the newest waiting row of the same kind and route has the same number and is recent.
    @discardableResult
    func log(kind: String, routeId: String?, predicted: Double, aux: Double? = nil,
             at: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Bool {
        try guardWritable()
        guard predicted.isFinite else { return false }
        return try database.writer.write { db -> Bool in
            let last = try Row.fetchOne(db, sql: """
                SELECT predicted, madeAt FROM prediction
                WHERE kind = ? AND routeId IS ? AND rideId IS NULL AND actual IS NULL ORDER BY madeAt DESC LIMIT 1
                """, arguments: [kind, routeId])
            if let last {
                let value: Double = last["predicted"]
                let made: Int64 = last["madeAt"]
                if abs(value - predicted) < 1e-9 && at - made < Self.dedupeMs { return false }
            }
            try db.execute(sql: "INSERT INTO prediction (kind, routeId, madeAt, predicted, aux) VALUES (?, ?, ?, ?, ?)",
                           arguments: [kind, routeId, at, predicted, aux])
            return true
        }
    }

    /// Predictions that have no ride yet, newest first.
    func waiting() throws -> [PredictionRecord] {
        try fetch(where: "rideId IS NULL AND actual IS NULL")
    }

    func all() throws -> [PredictionRecord] {
        try fetch(where: "1 = 1")
    }

    private func fetch(where clause: String) throws -> [PredictionRecord] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM prediction WHERE \(clause) ORDER BY madeAt DESC").map { row in
                PredictionRecord(id: row["id"], kind: row["kind"], routeId: row["routeId"], madeAt: row["madeAt"], predicted: row["predicted"],
                                 aux: row["aux"], rideId: row["rideId"], actual: row["actual"])
            }
        }
    }

    func settle(id: Int64, rideId: String, actual: Double, at: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE prediction SET rideId = ?, actual = ?, settledAt = ? WHERE id = ?", arguments: [rideId, actual, at, id])
        }
    }

    func delete(ids: [Int64]) throws {
        try guardWritable()
        guard !ids.isEmpty else { return }
        try database.writer.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM prediction WHERE id = ?", arguments: [id]) }
        }
    }

    /// Waiting predictions older than `olderThanMs` before `now` are removed.
    func prune(now: Int64, olderThanMs: Int64) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM prediction WHERE rideId IS NULL AND actual IS NULL AND madeAt < ?", arguments: [now - olderThanMs])
        }
    }

    func facts(rideId: String) throws -> PredictionRideFacts? {
        try database.writer.read { db -> PredictionRideFacts? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, routeId, startAt, endAt, lastMoveAt, totalS, distanceM, usedPct, startRestPct, endRestPct, energyWhRaw,
                       kind, status, isSimulated
                FROM ride WHERE id = ?
                """, arguments: [rideId]) else { return nil }
            let sim: Int = row["isSimulated"] ?? 0
            return PredictionRideFacts(id: row["id"], routeId: row["routeId"], startAt: row["startAt"], endAt: row["endAt"],
                                       lastMoveAt: row["lastMoveAt"], totalS: row["totalS"], distanceM: row["distanceM"],
                                       usedPct: row["usedPct"], startRestPct: row["startRestPct"], endRestPct: row["endRestPct"],
                                       energyWhRaw: row["energyWhRaw"], kind: row["kind"], status: row["status"], isSimulated: sim == 1)
        }
    }

    // MARK: Shadow

    func replaceShadow(rideId: String, rows: [(rule: String, variant: String, decision: String, differs: Bool, isStandard: Bool)]) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM shadow_result WHERE rideId = ?", arguments: [rideId])
            for r in rows {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO shadow_result (rideId, rule, variant, decision, differs, isStandard) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [rideId, r.rule, r.variant, r.decision, r.differs ? 1 : 0, r.isStandard ? 1 : 0])
            }
        }
    }

    /// Real rides only (simulated ones never count).
    func shadowRows() throws -> [ShadowStored] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ride.startAt AS startAt, s.rule AS rule, s.variant AS variant, s.decision AS decision, s.differs AS differs,
                       s.isStandard AS isStandard
                FROM shadow_result s JOIN ride ON ride.id = s.rideId WHERE ride.isSimulated = 0 ORDER BY ride.startAt DESC
                """).map { row in
                let differs: Int = row["differs"]
                let standard: Int = row["isStandard"]
                return ShadowStored(startAt: row["startAt"], rule: row["rule"], variant: row["variant"], decision: row["decision"],
                                    differs: differs == 1, isStandard: standard == 1)
            }
        }
    }

    /// The other rides on the ride's route (real, not excluded): their total times and used %.
    func otherRidesOnRoute(rideId: String) throws -> (otherTotalS: [Double], otherUsedPct: [Double])? {
        try database.writer.read { db -> (otherTotalS: [Double], otherUsedPct: [Double])? in
            guard let routeId = try String.fetchOne(db, sql: "SELECT routeId FROM ride WHERE id = ?", arguments: [rideId]) else { return nil }
            let rows = try Row.fetchAll(db, sql: """
                SELECT totalS, usedPct FROM ride
                WHERE routeId = ? AND id != ? AND kind = 'ride' AND status != 'recording' AND isSimulated = 0 AND excludedFromUsual = 0
                """, arguments: [routeId, rideId])
            var times: [Double] = []
            var used: [Double] = []
            for row in rows {
                if let t: Double = row["totalS"] { times.append(t) }
                if let u: Double = row["usedPct"] { used.append(u) }
            }
            return (otherTotalS: times, otherUsedPct: used)
        }
    }

    // MARK: Scenario list

    func scenarioRows() throws -> [ScenarioRow] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.id AS id, r.startAt AS startAt, r.endAt AS endAt, r.utcOffsetMin AS utcOffsetMin, r.totalS AS totalS,
                       r.distanceM AS distanceM, r.startRestPct AS startRestPct, r.wet AS wet, r.gapGpsS AS gapGpsS, r.hasGps AS hasGps,
                       r.loadKg AS loadKg, r.loadLevel AS loadLevel, r.routeId AS routeId, r.endReason AS endReason,
                       (SELECT s.batteryPct FROM ride_sample s WHERE s.rideId = r.id AND s.batteryPct IS NOT NULL
                        ORDER BY s.t LIMIT 1) AS firstPct,
                       (SELECT COUNT(*) FROM ride e WHERE e.routeId = r.routeId AND e.id != r.id AND e.startAt < r.startAt
                        AND e.kind = 'ride' AND e.isSimulated = 0) AS earlier
                FROM ride r
                WHERE r.isSimulated = 0 AND r.kind = 'ride' AND r.status IN ('ended', 'recovered') AND r.endAt IS NOT NULL
                ORDER BY r.startAt DESC
                """).map { row in
                let first: Int? = row["firstPct"]
                let routeId: String? = row["routeId"]
                let earlier: Int = row["earlier"] ?? 0
                let startRest: Double? = row["startRestPct"]
                let hasGps: Int? = row["hasGps"]
                return ScenarioRow(id: row["id"], startAt: row["startAt"], endAt: row["endAt"], utcOffsetMin: row["utcOffsetMin"] ?? 0,
                                   totalS: row["totalS"] ?? 0, distanceM: row["distanceM"] ?? 0,
                                   startPct: startRest ?? first.map(Double.init), wet: row["wet"], gapGpsS: row["gapGpsS"] ?? 0,
                                   hasGps: hasGps == 1, loadKg: row["loadKg"], loadLevel: row["loadLevel"],
                                   firstOnItsRoute: routeId == nil || earlier == 0, endReason: row["endReason"])
            }
        }
    }

    /// Rides that have a charge found after them (real rides)
    func chargedAfterRideIds() throws -> Set<String> {
        try database.writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT charge.afterRideId FROM charge JOIN ride ON ride.id = charge.afterRideId WHERE ride.isSimulated = 0
                """))
        }
    }
}
