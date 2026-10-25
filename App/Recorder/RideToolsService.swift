import CorckieCore
import Foundation
import GRDB

/// M5-01 / M5-02: compare, merge (with undo), trim (with reset). Pure rules live in CorckieCore (`RideTools/`);
/// this file reads and writes the rows. Every change runs in one transaction, then the numbers are recomputed from the samples.
enum RideToolsError: Error, LocalizedError {
    case notMergeable(String)
    case notTrimmable(String)
    case nothingToUndo

    var errorDescription: String? {
        switch self {
        case .notMergeable(let s), .notTrimmable(let s): return s
        case .nothingToUndo: return "There is nothing to undo."
        }
    }
}

/// F-39: the stop between merged legs on the ride summary
struct StopTrimState: Equatable {
    var stopS: Double
    var trimmed: Bool
}

enum RideToolsService {
    // MARK: Compare (M5-01)

    /// The newest rides as compare lines (simulated ones apart), with start / end places for the same-trip guess.
    static func compareRides(_ database: AppDatabase, limit: Int = 300) throws -> [CompareRide] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.id, r.startAt, r.utcOffsetMin, r.routeId, r.variantId, r.distanceM, r.totalS, r.movingS, r.avgMovingMps,
                       r.topSpeedMps, r.usedPct, r.elevGainM, r.energyWhRaw, r.isSimulated,
                       (SELECT lat FROM ride_sample s WHERE s.rideId = r.id AND s.lat IS NOT NULL ORDER BY s.t ASC LIMIT 1) AS sLat,
                       (SELECT lon FROM ride_sample s WHERE s.rideId = r.id AND s.lat IS NOT NULL ORDER BY s.t ASC LIMIT 1) AS sLon,
                       (SELECT lat FROM ride_sample s WHERE s.rideId = r.id AND s.lat IS NOT NULL ORDER BY s.t DESC LIMIT 1) AS eLat,
                       (SELECT lon FROM ride_sample s WHERE s.rideId = r.id AND s.lat IS NOT NULL ORDER BY s.t DESC LIMIT 1) AS eLon
                FROM ride r WHERE r.kind IN ('ride', 'shortHop') AND r.endAt IS NOT NULL
                ORDER BY r.startAt DESC LIMIT ?
                """, arguments: [limit])
            return rows.map { row in
                let startAt: Int64 = row["startAt"]
                let offset: Int? = row["utcOffsetMin"]
                let sim: Int = row["isSimulated"]
                return CompareRide(
                    id: row["id"], title: RideSummaryBuilder.title(startAt: startAt, utcOffsetMin: offset ?? 0), startAt: startAt,
                    routeId: row["routeId"], variantId: row["variantId"], distanceM: row["distanceM"], totalS: row["totalS"],
                    movingS: row["movingS"], avgMovingMps: row["avgMovingMps"], topSpeedMps: row["topSpeedMps"], usedPct: row["usedPct"],
                    elevGainM: row["elevGainM"], energyWhRaw: row["energyWhRaw"], startLat: row["sLat"], startLon: row["sLon"],
                    endLat: row["eLat"], endLon: row["eLon"], isSimulated: sim != 0)
            }
        }
    }

    // MARK: Merge offer (M5-02)

    /// The ride just before `rideId` and whether the two can be joined (30 min, 200 m).
    static func mergeOffer(_ database: AppDatabase, rideId: String) -> (previousId: String, previousTitle: String, offer: MergeOffer)? {
        let ends: [MergeEnd]? = try? database.writer.read { (db: Database) -> [MergeEnd]? in
            guard let this = try endOf(db, rideId: rideId) else { return nil }
            let prevId = try String.fetchOne(db, sql: """
                SELECT id FROM ride WHERE startAt < ? AND kind IN ('ride', 'shortHop') AND endAt IS NOT NULL AND isSimulated = ?
                ORDER BY startAt DESC LIMIT 1
                """, arguments: [this.startAt, this.isSimulated ? 1 : 0])
            guard let prevId, let prev = try endOf(db, rideId: prevId) else { return nil }
            return [prev, this]
        }
        guard let ends, ends.count == 2, let offer = RideMerge.offer(previous: ends[0], next: ends[1]) else { return nil }
        var title = "Previous ride"
        if let r = try? RideQueries(database).ride(id: ends[0].id) {
            title = RideSummaryBuilder.title(startAt: r.startAt, utcOffsetMin: r.utcOffsetMin ?? 0)
        }
        return (ends[0].id, title, offer)
    }

    private static func endOf(_ db: Database, rideId: String) throws -> MergeEnd? {
        guard let r = try Row.fetchOne(db, sql: "SELECT startAt, endAt, kind, isSimulated FROM ride WHERE id = ?", arguments: [rideId]) else { return nil }
        let first = try Row.fetchOne(db, sql: "SELECT lat, lon FROM ride_sample WHERE rideId = ? AND lat IS NOT NULL ORDER BY t ASC LIMIT 1", arguments: [rideId])
        let last = try Row.fetchOne(db, sql: "SELECT lat, lon FROM ride_sample WHERE rideId = ? AND lat IS NOT NULL ORDER BY t DESC LIMIT 1", arguments: [rideId])
        let sim: Int = r["isSimulated"]
        var startLat: Double?
        var startLon: Double?
        var endLat: Double?
        var endLon: Double?
        if let f = first {
            startLat = f["lat"]
            startLon = f["lon"]
        }
        if let l = last {
            endLat = l["lat"]
            endLon = l["lon"]
        }
        return MergeEnd(id: rideId, startAt: r["startAt"], endAt: r["endAt"], startLat: startLat, startLon: startLon,
                        endLat: endLat, endLon: endLon, isSimulated: sim != 0, kind: r["kind"])
    }

    // MARK: Merge

    private struct UndoNote: Codable {
        var first: String
        var second: String
        var file: String
        var at: Int64
    }

    static let undoKey = "merge.undo"

    static func defaultUndoFolder() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("undo", isDirectory: true)
    }

    /// Joins `secondId` onto `firstId` (the earlier ride). Returns the kept ride id.
    @discardableResult
    static func merge(_ database: AppDatabase, firstId: String, secondId: String, nowMs: Int64 = FactorUpdater.nowMs(),
                      undoFolder: URL = defaultUndoFolder()) throws -> String {
        let q = RideQueries(database)
        guard let a = try q.ride(id: firstId), let b = try q.ride(id: secondId), a.startAt < b.startAt, a.endAt != nil, b.endAt != nil else {
            throw RideToolsError.notMergeable("These two rides cannot be joined.")
        }
        guard a.trimStartAt == nil, b.trimStartAt == nil else {
            throw RideToolsError.notMergeable("Reset the trim of both rides first.")
        }
        // snapshot for Undo
        let snapshot: [RideBundle] = try database.writer.read { db in
            [try RideBundle.read(db, rideId: firstId), try RideBundle.read(db, rideId: secondId)].compactMap { $0 }
        }
        try FileManager.default.createDirectory(at: undoFolder, withIntermediateDirectories: true)
        let fileName = "merge-undo-\(firstId).json"
        try JSONEncoder().encode(snapshot).write(to: undoFolder.appendingPathComponent(fileName), options: .atomic)
        let note = UndoNote(first: firstId, second: secondId, file: fileName, at: nowMs)
        let noteJSON = String(data: try JSONEncoder().encode(note), encoding: .utf8) ?? "{}"

        let shift = RideMerge.shiftMs(firstStartAt: a.startAt, secondStartAt: b.startAt)
        try database.writer.write { db in
            let lastA = try Int64.fetchOne(db, sql: "SELECT MAX(t) FROM ride_sample WHERE rideId = ?", arguments: [firstId]) ?? 0
            let firstB = (try Int64.fetchOne(db, sql: "SELECT MIN(t) FROM ride_sample WHERE rideId = ?", arguments: [secondId]) ?? 0) + shift
            let fix = try Row.fetchOne(db, sql: "SELECT lat, lon FROM ride_sample WHERE rideId = ? AND lat IS NOT NULL ORDER BY t DESC LIMIT 1", arguments: [firstId])
            try db.execute(sql: "UPDATE ride_sample SET rideId = ?, t = t + ? WHERE rideId = ?", arguments: [firstId, shift, secondId])
            try db.execute(sql: "UPDATE gap SET rideId = ?, startT = startT + ?, endT = CASE WHEN endT IS NULL THEN NULL ELSE endT + ? END WHERE rideId = ?",
                           arguments: [firstId, shift, shift, secondId])
            try db.execute(sql: "UPDATE stop SET rideId = ?, startT = startT + ?, endT = CASE WHEN endT IS NULL THEN NULL ELSE endT + ? END WHERE rideId = ?",
                           arguments: [firstId, shift, shift, secondId])
            let maxSeq = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM raw_chunk WHERE rideId = ?", arguments: [firstId]) ?? -1
            try db.execute(sql: "UPDATE raw_chunk SET rideId = ?, seq = seq + ? WHERE rideId = ?", arguments: [firstId, maxSeq + 1, secondId])
            if firstB > lastA {
                var fixLat: Double?
                var fixLon: Double?
                if let f = fix {
                    fixLat = f["lat"]
                    fixLon = f["lon"]
                }
                let bridge = StopRecord(id: "bridge-\(UUID().uuidString)", rideId: firstId, startT: lastA, endT: firstB, lat: fixLat, lon: fixLon)
                try bridge.insert(db)
            }
            try db.execute(sql: "UPDATE charge SET afterRideId = ? WHERE afterRideId = ?", arguments: [firstId, secondId])
            try db.execute(sql: "UPDATE charge SET beforeRideId = ? WHERE beforeRideId = ?", arguments: [firstId, secondId])
            try db.execute(sql: "DELETE FROM insight WHERE rideId IN (?, ?)", arguments: [firstId, secondId])
            try db.execute(sql: "DELETE FROM ride_option WHERE rideId = ?", arguments: [firstId])
            try db.execute(sql: "DELETE FROM ride_climb WHERE rideId = ?", arguments: [firstId])
            try db.execute(sql: "DELETE FROM ride WHERE id = ?", arguments: [secondId])
            try db.execute(sql: """
                UPDATE ride SET endAt = ?, endReason = ?, status = ?, mergeGroupId = NULL, routeId = NULL, variantId = NULL,
                assignedByHand = 0, trimStartAt = NULL, trimEndAt = NULL WHERE id = ?
                """, arguments: [b.endAt, b.endReason, b.status, firstId])
            try db.execute(sql: "INSERT OR REPLACE INTO setting (key, json) VALUES (?, ?)", arguments: [undoKey, noteJSON])
        }
        try recompute(database, rideId: firstId, reclass: true)
        refresh(database, rideId: firstId, nowMs: nowMs, routes: true)
        return firstId
    }

    static func canUndoMerge(_ database: AppDatabase) -> Bool {
        guard let json = try? RideQueries(database).setting(key: undoKey), let data = json.data(using: .utf8),
              (try? JSONDecoder().decode(UndoNote.self, from: data)) != nil else { return false }
        return true
    }

    /// Puts the two rides back as they were before the last merge.
    static func undoMerge(_ database: AppDatabase, nowMs: Int64 = FactorUpdater.nowMs(), undoFolder: URL = defaultUndoFolder()) throws {
        guard let json = try RideQueries(database).setting(key: undoKey), let data = json.data(using: .utf8),
              let note = try? JSONDecoder().decode(UndoNote.self, from: data) else { throw RideToolsError.nothingToUndo }
        let file = undoFolder.appendingPathComponent(note.file)
        guard let bytes = try? Data(contentsOf: file), let bundles = try? JSONDecoder().decode([RideBundle].self, from: bytes),
              bundles.count == 2 else { throw RideToolsError.nothingToUndo }
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM ride WHERE id IN (?, ?)", arguments: [note.first, note.second])
            for bundle in bundles { try bundle.insert(db) }
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [undoKey])
        }
        try? FileManager.default.removeItem(at: file)
        _ = try? FactorUpdater.update(database, rideId: nil, nowMs: nowMs)
    }

    // MARK: Trim

    static func originalKey(_ rideId: String) -> String { "trim.original.\(rideId)" }

    /// The ride's trim window in seconds from its start, nil when not trimmed.
    static func trimWindow(_ ride: RideRecord) -> (start: Double, end: Double)? {
        guard let s = ride.trimStartAt, let e = ride.trimEndAt else { return nil }
        return (Double(s - ride.startAt) / 1000, Double(e - ride.startAt) / 1000)
    }

    /// Length of the ride's samples in seconds (nil without samples)
    static func lastSampleS(_ database: AppDatabase, rideId: String) -> Double? {
        guard let t = try? RideQueries(database).lastSampleT(rideId: rideId) else { return nil }
        return Double(t) / 1000
    }

    static func trim(_ database: AppDatabase, rideId: String, startS: Double, endS: Double, nowMs: Int64 = FactorUpdater.nowMs()) throws {
        let q = RideQueries(database)
        guard let r = try q.ride(id: rideId), r.endAt != nil, let last = lastSampleS(database, rideId: rideId),
              let window = RideTrim.clamp(startS: startS, endS: endS, lastS: last) else {
            throw RideToolsError.notTrimmable("This ride is too short to trim (at least one minute is kept).")
        }
        if r.trimStartAt == nil, try q.setting(key: originalKey(rideId)) == nil {
            let original = String(data: try JSONEncoder().encode(r), encoding: .utf8) ?? ""
            try q.setSetting(key: originalKey(rideId), json: original)
        }
        try recompute(database, rideId: rideId, trim: window, reclass: false)
        refresh(database, rideId: rideId, nowMs: nowMs, routes: false)
    }

    /// Brings back the numbers the ride had before its first trim.
    static func resetTrim(_ database: AppDatabase, rideId: String, nowMs: Int64 = FactorUpdater.nowMs()) throws {
        let q = RideQueries(database)
        guard let current = try q.ride(id: rideId), current.trimStartAt != nil else { return }
        if let json = try q.setting(key: originalKey(rideId)), let data = json.data(using: .utf8),
           var original = try? JSONDecoder().decode(RideRecord.self, from: data) {
            original.trimStartAt = nil
            original.trimEndAt = nil
            try q.save(original)
        } else {
            try recompute(database, rideId: rideId, trim: nil, reclass: false)
        }
        try database.writer.write { db in
            try db.execute(sql: "UPDATE ride SET trimStartAt = NULL, trimEndAt = NULL WHERE id = ?", arguments: [rideId])
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [originalKey(rideId)])
        }
        refresh(database, rideId: rideId, nowMs: nowMs, routes: false)
    }

    // MARK: Recompute

    /// The ride's numbers from its stored samples (optionally only inside a trim window).
    static func recompute(_ database: AppDatabase, rideId: String, trim: (start: Double, end: Double)? = nil, reclass: Bool) throws {
        let q = RideQueries(database)
        guard var r = try q.ride(id: rideId) else { return }
        let rows = try q.samples(rideId: rideId)
        let samples = rows.map(Recorder.sample(from:))
        let stopRows = try q.stops(rideId: rideId)
        func span(_ s: StopRecord) -> RideStopSpan { RideStopSpan(startT: Double(s.startT) / 1000, endT: s.endT.map { Double($0) / 1000 }) }
        let stops = stopRows.map(span)
        let bridges = stopRows.filter { $0.id.hasPrefix("bridge-") }.map(span)
        let m = RideRecompute.metrics(samples: samples, stops: stops, walks: walkSpans(rows), bridges: bridges,
                                      ignoredReadings: r.ignoredReadings, trimStartS: trim?.start, trimEndS: trim?.end)
        Recorder.fill(&r, m, topSpeedKmh: m.topSpeedKmh)
        if reclass, r.kind != "discarded" {
            let size = RideSizeClass.of(distanceM: m.distanceM)
            if size != .discarded { r.kind = size.rawValue }
        }
        if let f = m.firstMoveT { r.firstMoveAt = r.startAt + Int64((f * 1000).rounded()) }
        if let l = m.lastMoveT { r.lastMoveAt = r.startAt + Int64((l * 1000).rounded()) }
        if let t = trim {
            r.trimStartAt = r.startAt + Int64((t.start * 1000).rounded())
            r.trimEndAt = r.startAt + Int64((t.end * 1000).rounded())
        } else {
            r.trimStartAt = nil
            r.trimEndAt = nil
        }
        try q.save(r)
    }

    // MARK: F-39 the stop between merged legs

    /// The scooter-off stops between merged legs (the merge's bridges), s, and whether they are trimmed out of Time; nil = none
    static func stopTrimState(_ database: AppDatabase, rideId: String) -> StopTrimState? {
        let q = RideQueries(database)
        let bridges = ((try? q.stops(rideId: rideId)) ?? []).filter { $0.id.hasPrefix("bridge-") }
        let ms = bridges.reduce(Int64(0)) { $0 + max(0, ($1.endT ?? $1.startT) - $1.startT) }
        guard ms >= 60_000 else { return nil }
        let extras = RideExtras.parse(try? q.setting(key: RideExtras.key(rideId: rideId)))
        return StopTrimState(stopS: Double(ms) / 1000, trimmed: (extras.stopTrimmedS ?? 0) > 0)
    }

    /// F-39 flaw 7: "Includes a 25 min stop, trim it?" tapped (on = trim the stop out of Time) or undone (on = false)
    static func trimStops(_ database: AppDatabase, rideId: String, on: Bool) throws {
        let q = RideQueries(database)
        guard var r = try q.ride(id: rideId), let state = stopTrimState(database, rideId: rideId) else { return }
        var extras = RideExtras.parse(try? q.setting(key: RideExtras.key(rideId: rideId)))
        if on, !state.trimmed {
            r.totalS = max(0, (r.totalS ?? 0) - state.stopS)
            extras.stopTrimmedS = state.stopS
        } else if !on, state.trimmed {
            r.totalS = (r.totalS ?? 0) + (extras.stopTrimmedS ?? state.stopS)
            extras.stopTrimmedS = nil
        } else {
            return
        }
        try q.save(r)
        try q.setSetting(key: RideExtras.key(rideId: rideId), json: extras.json)
    }

    // MARK: B57 Restore discarded ride

    /// Discarded pieces of the last 30 days (real, ended), newest first: what "Restore discarded ride" offers.
    static func restoreCandidates(_ database: AppDatabase, nowMs: Int64 = FactorUpdater.nowMs()) -> [RideRecord] {
        let rows = ((try? RideQueries(database).rides(includeDiscarded: true)) ?? []).filter { $0.kind == "discarded" }
        let ids = PhoneRide.restoreCandidates(rows.map { (id: $0.id, startAt: $0.startAt, kind: $0.kind, isSimulated: $0.isSimulated, ended: !$0.isOpen) },
                                              nowMs: nowMs)
        return ids.compactMap { id in rows.first { $0.id == id } }
    }

    /// The phone's GPS distance of a stored ride, m (for the restore list and the restored ride's size)
    static func gpsDistanceM(_ database: AppDatabase, rideId: String) -> Double {
        let samples = ((try? RideQueries(database).samples(rideId: rideId)) ?? []).map(Recorder.sample(from:))
        return RideMetricsCalculator.compute(samples).gpsDistanceM
    }

    /// B57: a discarded piece becomes a ride again: numbers from its samples, GPS distance and top speed when the scooter's
    /// readings were lost, its own size class (never discarded again), then places, routes and factors as after a ride.
    static func restoreDiscarded(_ database: AppDatabase, rideId: String, nowMs: Int64 = FactorUpdater.nowMs()) throws {
        let q = RideQueries(database)
        guard let before = try q.ride(id: rideId), before.kind == "discarded" else { return }
        try recompute(database, rideId: rideId, reclass: false)
        guard var r = try q.ride(id: rideId) else { return }
        let samples = try q.samples(rideId: rideId).map(Recorder.sample(from:))
        let m = RideMetricsCalculator.compute(samples)
        let gapS = r.gapScooterS ?? 0
        let lost = gapS > 0 && m.gpsDistanceM > (r.distanceM ?? 0)
        r.distanceM = PhoneRide.distanceM(scooterM: r.distanceM ?? 0, gpsM: m.gpsDistanceM, scooterLost: lost)
        r.topSpeedMps = PhoneRide.topSpeedKmh(scooterKmh: (r.topSpeedMps ?? 0) * 3.6, gpsKmh: m.gpsTopSpeedKmh, scooterLost: lost) / 3.6
        if lost, let d = r.distanceM, let moving = r.movingS, moving > 0 { r.avgMovingMps = d / moving }
        r.kind = PhoneRide.restoredKind(distanceM: r.distanceM ?? 0, gpsM: m.gpsDistanceM).rawValue
        try q.save(r)
        if lost {
            var extras = RideExtras.parse(try? q.setting(key: RideExtras.key(rideId: rideId)))
            extras.recordedByPhone = true          // the scooter's readings were lost and the GPS carried the ride
            try q.setSetting(key: RideExtras.key(rideId: rideId), json: extras.json)
        }
        refresh(database, rideId: rideId, nowMs: nowMs, routes: true)
    }

    /// Stretches of samples marked as walking (pushing the scooter)
    static func walkSpans(_ rows: [RideSampleRecord]) -> [RideStopSpan] {
        var out: [RideStopSpan] = []
        var start: Double?
        var last: Double = 0
        for row in rows {
            let t = Double(row.t) / 1000
            if row.mode == "walk" {
                if start == nil { start = t }
                last = t
            } else if let s = start {
                out.append(RideStopSpan(startT: s, endT: last))
                start = nil
            }
        }
        if let s = start { out.append(RideStopSpan(startT: s, endT: last)) }
        return out
    }

    /// What depends on the numbers: battery calibration, factors, and for a merge the route and the insights. Never throws.
    private static func refresh(_ database: AppDatabase, rideId: String, nowMs: Int64, routes: Bool) {
        _ = try? CalibrationUpdater.update(database, nowMs: nowMs)
        if routes { _ = try? RouteProcessor.process(rideId: rideId, database: database) }
        _ = try? FactorUpdater.update(database, rideId: rideId, nowMs: nowMs)
        _ = try? FastestService.update(database, rideId: rideId)                 // M6-01: choice points (Q23, Q3)
        if routes { _ = try? InsightRunner.afterRide(database, rideId: rideId, nowMs: nowMs) }
    }
}
