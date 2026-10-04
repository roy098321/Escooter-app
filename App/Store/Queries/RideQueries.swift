import Foundation
import GRDB

/// M1-08: reading and writing rides (DATA_MODEL section 2). One value type over `AppDatabase`; the Recorder
/// (M1-09) writes through it, the ride lists and the ride detail read through it.
/// A read-only database (V6, data from a newer build) refuses every write.
struct RideQueries {
    enum StoreError: Error, LocalizedError {
        case readOnly

        var errorDescription: String? { "The database is read-only (it was written by a newer build)" }
    }

    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    private var writer: any DatabaseWriter { database.writer }

    private func requireWritable() throws {
        if database.isReadOnly { throw StoreError.readOnly }
    }

    // MARK: Writing

    /// Inserts the ride, or updates it when the id exists. Updates never delete the ride's samples.
    func save(_ ride: RideRecord) throws {
        try requireWritable()
        try writer.write { db in try ride.upsert(db) }
    }

    /// One transaction for the whole batch (the Recorder writes every few seconds).
    func insert(samples: [RideSampleRecord]) throws {
        try requireWritable()
        guard !samples.isEmpty else { return }
        try writer.write { db in
            for sample in samples { try sample.insert(db) }
        }
    }

    func insert(chunk: RawChunkRecord) throws {
        try requireWritable()
        try writer.write { db in try chunk.insert(db) }
    }

    /// Opens a gap; returns it with its id so it can be closed later.
    @discardableResult
    func openGap(rideId: String, kind: String, startT: Int64) throws -> GapRecord {
        try requireWritable()
        return try writer.write { db in
            var gap = GapRecord(id: nil, rideId: rideId, kind: kind, startT: startT, endT: nil)
            try gap.insert(db)
            return gap
        }
    }

    func closeGap(id: Int64, endT: Int64) throws {
        try requireWritable()
        try writer.write { db in
            try db.execute(sql: "UPDATE gap SET endT = ? WHERE id = ?", arguments: [endT, id])
        }
    }

    func save(stop: StopRecord) throws {
        try requireWritable()
        try writer.write { db in try stop.upsert(db) }
    }

    /// Deletes a ride; its samples, raw chunks, gaps, stops and per-ride rows go with it
    /// (ON DELETE CASCADE, foreign keys are on). Returns false when there was no such ride.
    @discardableResult
    func delete(rideId: String) throws -> Bool {
        try requireWritable()
        return try writer.write { db in
            try db.execute(sql: "DELETE FROM ride WHERE id = ?", arguments: [rideId])
            return db.changesCount > 0
        }
    }

    // MARK: Reading

    func ride(id: String) throws -> RideRecord? {
        try writer.read { db in try RideRecord.fetchOne(db, key: id) }
    }

    /// Newest first. Discarded pieces (kind `discarded`) are left out unless asked for.
    func rides(includeDiscarded: Bool = false, limit: Int? = nil) throws -> [RideRecord] {
        try writer.read { db in
            var request = RideRecord.all().order(Column("startAt").desc)
            if !includeDiscarded { request = request.filter(Column("kind") != "discarded") }
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
    }

    /// The rides grouped by local calendar day (`yyyy-MM-dd`, using each ride's own UTC offset;
    /// offset unknown = `fallbackUtcOffsetMin`), newest day first, newest ride first inside a day.
    func ridesByDay(fallbackUtcOffsetMin: Int = 0) throws -> [(day: String, rides: [RideRecord])] {
        let all = try rides()
        var groups: [String: [RideRecord]] = [:]
        for ride in all {
            let key = Self.dayKey(startAt: ride.startAt, utcOffsetMin: ride.utcOffsetMin ?? fallbackUtcOffsetMin)
            groups[key, default: []].append(ride)
        }
        return groups.keys.sorted(by: >).map { (day: $0, rides: groups[$0] ?? []) }
    }

    /// `yyyy-MM-dd` of an epoch-ms instant at a UTC offset. Pure (no time zone database).
    static func dayKey(startAt: Int64, utcOffsetMin: Int) -> String {
        let seconds = startAt / 1000 + Int64(utcOffsetMin) * 60
        let days = Int((Double(seconds) / 86_400).rounded(.down))
        // civil-from-days (Howard Hinnant), valid for the whole Gregorian range
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let year = m <= 2 ? y + 1 : y
        return String(format: "%04d-%02d-%02d", year, m, d)
    }

    func samples(rideId: String) throws -> [RideSampleRecord] {
        try writer.read { db in
            try RideSampleRecord.filter(Column("rideId") == rideId).order(Column("t")).fetchAll(db)
        }
    }

    func sampleCount(rideId: String) throws -> Int {
        try writer.read { db in try RideSampleRecord.filter(Column("rideId") == rideId).fetchCount(db) }
    }

    func chunks(rideId: String) throws -> [RawChunkRecord] {
        try writer.read { db in
            try RawChunkRecord.filter(Column("rideId") == rideId).order(Column("seq")).fetchAll(db)
        }
    }

    func gaps(rideId: String) throws -> [GapRecord] {
        try writer.read { db in
            try GapRecord.filter(Column("rideId") == rideId).order(Column("startT")).fetchAll(db)
        }
    }

    func stops(rideId: String) throws -> [StopRecord] {
        try writer.read { db in
            try StopRecord.filter(Column("rideId") == rideId).order(Column("startT")).fetchAll(db)
        }
    }

    /// Rides still marked `recording` (recovery at launch, M1-04 / M1-09).
    func openRides() throws -> [RideRecord] {
        try writer.read { db in try RideRecord.filter(Column("status") == "recording").fetchAll(db) }
    }
}

// MARK: Simulator database (M1 plan section 6 decision 3)

extension AppDatabase {
    /// A database with the same schema in a temporary folder, for the in-app simulator: the
    /// real `corckie.sqlite` is never opened, written or copied. Remove it with `discardTemporary()`.
    static func openTemporary(build: String) throws -> AppDatabase {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-sim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: build)
    }

    /// Deletes the folder of a database made by `openTemporary` (never the real one).
    func discardTemporary() {
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix("corckie-sim-") else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
