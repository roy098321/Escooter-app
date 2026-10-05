import CorckieCore
import Foundation
import GRDB

/// M4-03: the `insight` table (migration v1, no schema change) and what the insights read from the ride tables.
///
/// Encoding: `type` = the catalogue type ("q4After"), "progress.<type>" for a pattern D line; `moment` = start / after /
/// weekly / notify / recent ("recent" = made after the ride's summary was seen: Recent insights only); `score` = class + size
/// (freshness is added when ranking); `expiresAt` for start / notification / weekly rows. Hand-off to M4-04 ... M4-10:
/// `top(forRide:)`, `more(forRide:)`, `progress(forRide:)`, `recent(limit:)`, `weekCard(weekStart:)`, `markShown`, `dismiss`.
struct InsightRideRow: Equatable {
    var id: String
    var routeId: String?
    var variantId: String?
    var startAt: Int64
    var endAt: Int64?
    var utcOffsetMin: Int?
    var kind: String
    var isSimulated: Bool
    var distanceM: Double?
    var totalS: Double?
    var movingS: Double?
    var usedPct: Double?
    var headwindKmh: Double?
    var loadKg: Double?
    var loadLevel: String?
    var timeAtMaxPct: Double?
}

struct InsightQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    private func guardWritable() throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
    }

    // MARK: insight rows

    static func decode(_ row: Row) -> Insight? {
        guard let stored: String = row["type"], let parsed = Insight.parse(storedType: stored) else { return nil }
        var i = Insight(type: parsed.type, rideId: row["rideId"], routeId: row["routeId"], weekStart: row["weekStart"], subject: nil,
                        text: row["text"] ?? "", basedOnN: row["basedOnN"] ?? 0, isProgress: parsed.progress, createdAt: row["createdAt"] ?? 0)
        i.id = row["id"]
        if let m: String = row["moment"], let moment = InsightMoment(rawValue: m) { i.moment = moment }
        i.score = row["score"] ?? 0
        i.expiresAt = row["expiresAt"]
        i.shownAt = row["shownAt"]
        i.dismissedAt = row["dismissedAt"]
        return i
    }

    private func fetch(_ sql: String, _ arguments: StatementArguments = []) throws -> [Insight] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM insight " + sql, arguments: arguments).compactMap(Self.decode)
        }
    }

    func all() throws -> [Insight] { try fetch("ORDER BY createdAt") }

    func forRide(_ rideId: String) throws -> [Insight] { try fetch("WHERE rideId = ? ORDER BY createdAt", [rideId]) }

    func forWeek(_ weekStart: Int64) throws -> [Insight] { try fetch("WHERE weekStart = ? ORDER BY createdAt", [weekStart]) }

    /// Rows a run must dedupe against: this ride's, plus every once-only / cooldown type (any ride)
    func existing(forRide rideId: String?) throws -> [Insight] {
        let types = InsightType.allCases.filter { $0.dedupe == .once || $0.cooldownDays > 0 || $0.dedupe == .perDay }.map(\.rawValue)
        let marks = types.map { _ in "?" }.joined(separator: ",")
        var args: [DatabaseValueConvertible?] = types.map { $0 as DatabaseValueConvertible? }
        var sql = "WHERE type IN (\(marks))"
        if let rideId {
            sql += " OR rideId = ?"
            args.append(rideId)
        }
        return try fetch(sql, StatementArguments(args))
    }

    /// Writes a merge (new rows and updated numbers) and removes this ride's progress lines that are no longer made.
    func save(_ merge: InsightMerge, rideId: String? = nil, keepProgress: Set<String> = []) throws {
        try guardWritable()
        try database.writer.write { db in
            if let rideId {
                let stale = try String.fetchAll(db, sql: "SELECT id FROM insight WHERE rideId = ? AND type LIKE 'progress.%'", arguments: [rideId])
                for id in stale where !keepProgress.contains(id) {
                    try db.execute(sql: "DELETE FROM insight WHERE id = ?", arguments: [id])
                }
            }
            for i in merge.insert {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO insight (id, type, moment, rideId, routeId, weekStart, text, basedOnN, score, createdAt, shownAt, dismissedAt, expiresAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [i.id, i.storedType, i.moment.rawValue, i.rideId, i.routeId, i.weekStart, i.text, i.basedOnN, i.score, i.createdAt,
                                     i.shownAt, i.dismissedAt, i.expiresAt])
            }
            for i in merge.update {
                try db.execute(sql: "UPDATE insight SET text = ?, basedOnN = ?, score = ? WHERE id = ?",
                               arguments: [i.text, i.basedOnN, i.score, i.id])
            }
        }
    }

    /// The summary / ride detail was shown (M4-10): later cards for this ride go to Recent insights only.
    func markShown(rideId: String, at ms: Int64) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE insight SET shownAt = ? WHERE rideId = ? AND shownAt IS NULL AND moment = 'after'", arguments: [ms, rideId])
        }
    }

    func dismiss(id: String, at ms: Int64) throws {
        try guardWritable()
        try database.writer.write { db in
            try db.execute(sql: "UPDATE insight SET dismissedAt = ? WHERE id = ?", arguments: [ms, id])
        }
    }

    /// The ride's summary was already seen (a shown after-ride row)
    func summarySeen(rideId: String) throws -> Bool {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight WHERE rideId = ? AND shownAt IS NOT NULL", arguments: [rideId]) ?? 0
        } > 0
    }

    /// The top card types of the last 3 rides before this one (freshness, 9.3)
    func recentTopTypes(before rideId: String, limit: Int = InsightRanking.freshnessRides) throws -> [InsightType] {
        let ids: [String] = try database.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT rideId FROM insight WHERE rideId IS NOT NULL AND rideId != ? AND moment = 'after'
                GROUP BY rideId ORDER BY MAX(createdAt) DESC LIMIT ?
                """, arguments: [rideId, limit])
        }
        return try ids.compactMap { id in
            InsightRanking.rank(try forRide(id), recentTopTypes: [], nowMs: Int64.max / 2).top?.type
        }
    }

    // MARK: Hand-off reads (M4-04 ... M4-10)

    func ranked(forRide rideId: String, nowMs: Int64) throws -> RankedInsights {
        InsightRanking.rank(try forRide(rideId), recentTopTypes: try recentTopTypes(before: rideId), nowMs: nowMs)
    }

    func top(forRide rideId: String, nowMs: Int64) throws -> Insight? { try ranked(forRide: rideId, nowMs: nowMs).top }

    func more(forRide rideId: String, nowMs: Int64) throws -> [Insight] { try ranked(forRide: rideId, nowMs: nowMs).more }

    func progress(forRide rideId: String, nowMs: Int64) throws -> [Insight] { try ranked(forRide: rideId, nowMs: nowMs).progress }

    /// Recent insights (Stats): the last 10 by time
    func recent(limit: Int = InsightRanking.recentLimit) throws -> [Insight] {
        InsightRanking.recent(try fetch("WHERE type NOT LIKE 'progress.%' ORDER BY createdAt DESC LIMIT ?", [limit * 3]), limit: limit)
    }

    /// The week card: Q22 first, then Q4-weekly and Q13-weekly
    func weekCard(weekStart: Int64) throws -> [Insight] {
        let order: [InsightType] = [.q22Weekly, .q4Weekly, .q13Weekly]
        return try forWeek(weekStart).filter { $0.moment == .weekly }
            .sorted { (order.firstIndex(of: $0.type) ?? 9) < (order.firstIndex(of: $1.type) ?? 9) }
    }

    func count() throws -> (rows: Int, progress: Int) {
        try database.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight WHERE type LIKE 'progress.%'") ?? 0)
        }
    }

    // MARK: What the generators read

    func ride(_ rideId: String) throws -> InsightRideRow? {
        try database.writer.read { db in
            guard let r = try Row.fetchOne(db, sql: """
                SELECT id, routeId, variantId, startAt, endAt, utcOffsetMin, kind, isSimulated, distanceM, totalS, movingS, usedPct, headwindKmh,
                       loadKg, loadLevel, timeAtMaxPct FROM ride WHERE id = ?
                """, arguments: [rideId]) else { return nil }
            return InsightRideRow(id: r["id"], routeId: r["routeId"], variantId: r["variantId"], startAt: r["startAt"], endAt: r["endAt"],
                                  utcOffsetMin: r["utcOffsetMin"], kind: r["kind"], isSimulated: r["isSimulated"], distanceM: r["distanceM"],
                                  totalS: r["totalS"], movingS: r["movingS"], usedPct: r["usedPct"], headwindKmh: r["headwindKmh"],
                                  loadKg: r["loadKg"], loadLevel: r["loadLevel"], timeAtMaxPct: r["timeAtMaxPct"])
        }
    }

    /// Ended rides (ride or short hop) of the same kind of data (real or simulated), for "first ride"
    func endedRideCount(simulated: Bool) throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ride WHERE endAt IS NOT NULL AND kind IN ('ride', 'shortHop') AND isSimulated = ?",
                             arguments: [simulated]) ?? 0
        }
    }

    /// Ended rides in [from, to) for the week (real rides only)
    func weekRides(from: Int64, to: Int64) throws -> [(id: String, ride: WeekRide)] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, startAt, utcOffsetMin, kind, distanceM, totalS, movingS, usedPct, timeAtMaxPct FROM ride
                WHERE endAt IS NOT NULL AND kind IN ('ride', 'shortHop') AND isSimulated = 0 AND startAt >= ? AND startAt < ? ORDER BY startAt
                """, arguments: [from, to])
            var out: [(id: String, ride: WeekRide)] = []
            for r in rows {
                let id: String = r["id"]
                let start: Int64 = r["startAt"]
                let kind: String = r["kind"]
                let offset: Int? = r["utcOffsetMin"]
                let distance: Double? = r["distanceM"]
                let total: Double? = r["totalS"]
                let moving: Double? = r["movingS"]
                let used: Double? = r["usedPct"]
                let atMax: Double? = r["timeAtMaxPct"]
                out.append((id: id, ride: WeekRide(startAt: start, utcOffsetMin: offset ?? 0, kind: kind, distanceM: distance ?? 0,
                                                   totalS: total ?? 0, movingS: moving, usedPct: used, timeAtMaxPct: atMax)))
            }
            return out
        }
    }

    /// Q13: the route's rides with a time at max (M20; none until it is filled, D7 point 3)
    func capRides(routeId: String) throws -> [CapRide] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT timeAtMaxPct, totalS, usedPct FROM ride WHERE routeId = ? AND kind = 'ride' AND excludedFromUsual = 0
                AND timeAtMaxPct IS NOT NULL AND totalS IS NOT NULL
                """, arguments: [routeId]).map { r -> CapRide in
                let share: Double = r["timeAtMaxPct"]
                let total: Double = r["totalS"]
                let used: Double? = r["usedPct"]
                return CapRide(timeAtMaxPct: share, totalS: total, usedPct: used)
            }
        }
    }

    /// Q17: climbs first seen during this ride (the `climb` table; filled by the climb detector)
    func newClimbs(routeId: String, from: Int64, to: Int64) throws -> [(id: String, name: String?, gainM: Double)] {
        try database.writer.read { db in
            var out: [(id: String, name: String?, gainM: Double)] = []
            for r in try Row.fetchAll(db, sql: "SELECT id, name, gainM FROM climb WHERE routeId = ? AND firstSeenAt >= ? AND firstSeenAt <= ?",
                                      arguments: [routeId, from, to]) {
                let id: String = r["id"]
                let name: String? = r["name"]
                let gain: Double? = r["gainM"]
                out.append((id: id, name: name, gainM: gain ?? 0))
            }
            return out
        }
    }

    struct OptionTimes {
        var optionId: String
        var name: String?
        var rideTimeS: Double
        var optionTimesS: [Double]
        var otherTimesS: [Double]
    }

    /// Q3: for each option this ride went through, its times and the other options' times at the same choice point
    func optionTimes(rideId: String) throws -> [OptionTimes] {
        try database.writer.read { db in
            let mine = try Row.fetchAll(db, sql: """
                SELECT ro.optionId, ro.timeS, co.choicePointId, co.name FROM ride_option ro JOIN choice_option co ON co.id = ro.optionId
                WHERE ro.rideId = ? AND ro.timeS IS NOT NULL
                """, arguments: [rideId])
            var out: [OptionTimes] = []
            for m in mine {
                let optionId: String = m["optionId"]
                let point: String? = m["choicePointId"]
                let own = try Double.fetchAll(db, sql: """
                    SELECT ro.timeS FROM ride_option ro JOIN ride r ON r.id = ro.rideId WHERE ro.optionId = ? AND ro.timeS IS NOT NULL
                    AND r.excludedFromUsual = 0 ORDER BY r.startAt
                    """, arguments: [optionId])
                let other = try Double.fetchAll(db, sql: """
                    SELECT ro.timeS FROM ride_option ro JOIN choice_option co ON co.id = ro.optionId JOIN ride r ON r.id = ro.rideId
                    WHERE co.choicePointId = ? AND ro.optionId != ? AND ro.timeS IS NOT NULL AND r.excludedFromUsual = 0
                    """, arguments: [point, optionId])
                out.append(OptionTimes(optionId: optionId, name: m["name"], rideTimeS: m["timeS"], optionTimesS: own, otherTimesS: other))
            }
            return out
        }
    }
}
