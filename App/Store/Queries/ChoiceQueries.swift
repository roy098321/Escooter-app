import CorckieCore
import Foundation
import GRDB

/// M6-01 (Q23): the tables of migration v1 for choice points (`choice_point`, `choice_option`, `ride_option`): the timed GPS of a
/// route's rides in, the detected set out (replaced per route after every ride), and the set read back for the route card,
/// Follow and Q3 (`InsightQueries.optionTimes` reads `ride_option` too). No schema change.
struct ChoiceQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    private var writer: any DatabaseWriter { database.writer }

    /// The newest rides of a route with their timed fixes (t in seconds since the start; energy integrated from power).
    func rides(routeId: String, limit: Int) throws -> [ChoiceRide] {
        try writer.read { db in
            let ids = try Row.fetchAll(db, sql: """
                SELECT id, startAt FROM ride WHERE routeId = ? AND kind != 'discarded' AND status != 'recording'
                ORDER BY startAt DESC LIMIT ?
                """, arguments: [routeId, limit])
            var out: [ChoiceRide] = []
            for row in ids {
                let id: String = row["id"]
                let startAt: Int64 = row["startAt"]
                let samples = try Row.fetchAll(db, sql: """
                    SELECT t, lat, lon, hAccM, batteryPct, powerW FROM ride_sample WHERE rideId = ? ORDER BY t
                    """, arguments: [id])
                var fixes: [TimedFix] = []
                var wh = 0.0
                var lastT: Double?
                var lastW: Double?
                for s in samples {
                    let t = Double(s["t"] as Int64) / 1000
                    let w: Double? = s["powerW"]
                    if let lt = lastT, let lw = lastW, t > lt, t - lt <= 10 { wh += max(0, lw) * (t - lt) / 3600 }
                    lastT = t
                    if let w { lastW = w }
                    guard let lat: Double = s["lat"], let lon: Double = s["lon"] else { continue }
                    let pct: Int? = s["batteryPct"]
                    fixes.append(TimedFix(t: t, lat: lat, lon: lon, hAccM: s["hAccM"], batteryPct: pct.map(Double.init),
                                          energyWh: lastW == nil ? nil : wh))
                }
                out.append(ChoiceRide(id: id, startAt: startAt, fixes: fixes))
            }
            return out.reversed()
        }
    }

    /// Replaces the route's choice points, options and the `ride_option` rows of its rides.
    func replace(routeId: String, with set: ChoiceSet) throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
        try writer.write { db in
            try db.execute(sql: "DELETE FROM ride_option WHERE rideId IN (SELECT id FROM ride WHERE routeId = ?)", arguments: [routeId])
            try db.execute(sql: "DELETE FROM ride_option WHERE optionId IN (SELECT o.id FROM choice_option o JOIN choice_point p ON p.id = o.choicePointId WHERE p.routeId = ?)",
                           arguments: [routeId])
            try db.execute(sql: "DELETE FROM choice_point WHERE routeId = ?", arguments: [routeId])      // options cascade
            for p in set.points {
                try db.execute(sql: """
                    INSERT INTO choice_point (id, routeId, splitLat, splitLon, rejoinLat, rejoinLon, posOnRefM, sideTag) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                    """, arguments: [p.id, routeId, p.split.lat, p.split.lon, p.rejoin.lat, p.rejoin.lon, p.posOnRefM])
                for o in p.options {
                    try db.execute(sql: "INSERT INTO choice_option (id, choicePointId, polyline, lengthM, name) VALUES (?, ?, ?, ?, ?)",
                                   arguments: [o.id, p.id, Geo.encode(o.path), o.lengthM, o.name])
                }
            }
            for c in set.costs {
                try db.execute(sql: "INSERT OR REPLACE INTO ride_option (rideId, optionId, timeS, energyWh, usedPct) VALUES (?, ?, ?, ?, ?)",
                               arguments: [c.rideId, c.optionId, c.timeS, c.energyWh, c.usedPct])
            }
        }
    }

    /// The stored set of a route (options in stored order: the usual way first). The rejoin position is found again on the reference.
    func set(routeId: String, reference: [GeoPoint]) throws -> ChoiceSet {
        try writer.read { db in
            let pointRows = try Row.fetchAll(db, sql: "SELECT * FROM choice_point WHERE routeId = ? ORDER BY posOnRefM", arguments: [routeId])
            var points: [ChoicePoint] = []
            for r in pointRows {
                let id: String = r["id"]
                let options = try Row.fetchAll(db, sql: "SELECT * FROM choice_option WHERE choicePointId = ? ORDER BY rowid", arguments: [id]).map { o in
                    ChoiceOption(id: o["id"], choicePointId: id, path: Geo.decode(o["polyline"] ?? ""), lengthM: o["lengthM"] ?? 0,
                                 name: o["name"] ?? "way", isReference: (o["id"] as String).hasSuffix(":ref"))
                }
                let split = GeoPoint(lat: r["splitLat"] ?? 0, lon: r["splitLon"] ?? 0)
                let rejoin = GeoPoint(lat: r["rejoinLat"] ?? 0, lon: r["rejoinLon"] ?? 0)
                let pos: Double = r["posOnRefM"] ?? 0
                var rejoinPos = pos
                if let refOption = options.first(where: { $0.isReference }) { rejoinPos = pos + refOption.lengthM }
                points.append(ChoicePoint(id: id, routeId: routeId, split: split, rejoin: rejoin, posOnRefM: pos, rejoinOnRefM: rejoinPos,
                                          options: options))
            }
            let costs = try Row.fetchAll(db, sql: """
                SELECT ro.rideId, ro.optionId, ro.timeS, ro.energyWh, ro.usedPct, o.choicePointId FROM ride_option ro
                JOIN choice_option o ON o.id = ro.optionId JOIN choice_point p ON p.id = o.choicePointId
                WHERE p.routeId = ? AND ro.timeS IS NOT NULL
                """, arguments: [routeId]).map { c in
                RideOptionCost(rideId: c["rideId"], optionId: c["optionId"], choicePointId: c["choicePointId"], timeS: c["timeS"],
                               usedPct: c["usedPct"], energyWh: c["energyWh"])
            }
            return ChoiceSet(points: points, costs: costs)
        }
    }

    func counts(routeId: String) throws -> (points: Int, options: Int, rideOptions: Int) {
        try writer.read { db in
            let p = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM choice_point WHERE routeId = ?", arguments: [routeId]) ?? 0
            let o = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM choice_option o JOIN choice_point p ON p.id = o.choicePointId WHERE p.routeId = ?",
                                     arguments: [routeId]) ?? 0
            let r = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM ride_option ro JOIN choice_option o ON o.id = ro.optionId JOIN choice_point p ON p.id = o.choicePointId
                WHERE p.routeId = ?
                """, arguments: [routeId]) ?? 0
            return (p, o, r)
        }
    }
}
