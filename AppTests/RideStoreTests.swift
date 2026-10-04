import Foundation
import GRDB
import XCTest

/// M1-08: ride storage on the real schema (migration v1, no schema change), including the frozen
/// 0.4 database ("update keeps data") and the temporary simulator database.
final class RideStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-ride-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var dbURL: URL { folder.appendingPathComponent("corckie.sqlite") }

    private func frozenCopy() throws -> URL {
        let source = try XCTUnwrap(Bundle(for: RideStoreTests.self).url(forResource: "p4-foundation", withExtension: "sqlite"))
        try FileManager.default.copyItem(at: source, to: dbURL)
        return dbURL
    }

    private func ms(_ iso: String) throws -> Int64 {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func makeRide(_ id: String, startAt: Int64, samples: Int = 0) -> (RideRecord, [RideSampleRecord]) {
        var ride = RideRecord(id: id, startAt: startAt)
        ride.scooterId = nil
        ride.createdBuild = "test"
        var rows: [RideSampleRecord] = []
        for i in 0..<samples {
            var s = RideSampleRecord(rideId: id, t: Int64(i) * 5_000)
            s.speedMps = Double(i % 10)
            s.voltage = 50
            s.currentA = 4
            s.batteryPct = 90
            s.odometerKm = 100 + Double(i) / 100
            s.mode = "scooter"
            s.moving = true
            rows.append(s)
        }
        return (ride, rows)
    }

    // MARK: write / read

    func test_writeAndRead_rideSamplesChunksGapsStops() throws {
        let db = try AppDatabase(url: dbURL, build: "t1")
        let store = RideQueries(db)
        var (ride, samples) = makeRide("r1", startAt: try ms("2026-10-04T06:00:00Z"), samples: 1_000)
        ride.kind = "ride"
        ride.utcOffsetMin = 180
        ride.distanceM = 13_700
        ride.energyWhRaw = 322.5
        ride.hasGps = true
        ride.elevProvisional = true
        try store.save(ride)
        try store.insert(samples: samples)
        try store.insert(chunk: RawChunkRecord(rideId: "r1", seq: 0, startAt: 0, endAt: 30_000, kind: "scooter", blob: Data([1, 2, 3, 4])))
        try store.insert(chunk: RawChunkRecord(rideId: "r1", seq: 1, startAt: 30_000, endAt: 60_000, kind: "scooter", blob: Data([5])))
        let gap = try store.openGap(rideId: "r1", kind: "scooter", startT: 100_000)
        let gapId = try XCTUnwrap(gap.id)
        try store.closeGap(id: gapId, endT: 140_000)
        let stop = StopRecord(rideId: "r1", startT: 200_000, endT: 215_000, lat: 10.0, lon: -30.0)
        try store.save(stop: stop)

        XCTAssertEqual(try store.ride(id: "r1"), ride)
        XCTAssertEqual(try store.sampleCount(rideId: "r1"), 1_000)
        XCTAssertEqual(try store.samples(rideId: "r1"), samples)
        XCTAssertEqual(try store.chunks(rideId: "r1").map(\.seq), [0, 1])
        XCTAssertEqual(try store.chunks(rideId: "r1").first?.blob, Data([1, 2, 3, 4]))
        XCTAssertEqual(try store.chunks(rideId: "r1").first?.codec, "zlib-v1")
        let gaps = try store.gaps(rideId: "r1")
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.startT, 100_000)
        XCTAssertEqual(gaps.first?.endT, 140_000)
        XCTAssertEqual(try store.stops(rideId: "r1"), [stop])
        XCTAssertEqual(try store.openRides().map(\.id), ["r1"], "status defaults to recording")
    }

    func test_update_keepsSamples_andSameSecondReplaces() throws {
        let db = try AppDatabase(url: dbURL, build: "t1")
        let store = RideQueries(db)
        var (ride, samples) = makeRide("r1", startAt: 1_000_000, samples: 10)
        try store.save(ride)
        try store.insert(samples: samples)
        ride.status = "ended"
        ride.endAt = 1_060_000
        ride.endReason = "standstill"
        try store.save(ride)
        XCTAssertEqual(try store.ride(id: "r1")?.status, "ended")
        XCTAssertEqual(try store.sampleCount(rideId: "r1"), 10, "updating the ride row must not touch its samples")
        XCTAssertTrue(try store.openRides().isEmpty)

        samples[3].speedMps = 99
        try store.insert(samples: [samples[3]])
        XCTAssertEqual(try store.sampleCount(rideId: "r1"), 10)
        XCTAssertEqual(try store.samples(rideId: "r1")[3].speedMps, 99)
    }

    func test_sampleForUnknownRide_isRefused() throws {
        let db = try AppDatabase(url: dbURL, build: "t1")
        let store = RideQueries(db)
        XCTAssertThrowsError(try store.insert(samples: [RideSampleRecord(rideId: "nope", t: 0)]), "foreign keys are on")
        XCTAssertThrowsError(try store.insert(chunk: RawChunkRecord(rideId: "nope", seq: 0, startAt: 0, endAt: 1, kind: "scooter", blob: Data())))
    }

    // MARK: lists by day

    func test_dayKey_usesTheRidesOwnUtcOffset() throws {
        XCTAssertEqual(RideQueries.dayKey(startAt: try ms("2026-10-04T21:30:00Z"), utcOffsetMin: 0), "2026-10-04")
        XCTAssertEqual(RideQueries.dayKey(startAt: try ms("2026-10-04T21:30:00Z"), utcOffsetMin: 180), "2026-10-05")
        XCTAssertEqual(RideQueries.dayKey(startAt: try ms("2026-10-04T01:30:00Z"), utcOffsetMin: -300), "2026-10-03")
        XCTAssertEqual(RideQueries.dayKey(startAt: try ms("2024-02-29T12:00:00Z"), utcOffsetMin: 0), "2024-02-29", "leap day")
        XCTAssertEqual(RideQueries.dayKey(startAt: try ms("2025-03-01T00:00:00Z"), utcOffsetMin: 0), "2025-03-01")
        XCTAssertEqual(RideQueries.dayKey(startAt: try ms("1999-12-31T23:59:59Z"), utcOffsetMin: 0), "1999-12-31")
    }

    func test_ridesByDay_groupsNewestFirst_andHidesDiscarded() throws {
        let db = try AppDatabase(url: dbURL, build: "t1")
        let store = RideQueries(db)
        var a = RideRecord(id: "a", startAt: try ms("2026-10-04T05:00:00Z"))
        a.utcOffsetMin = 180
        var b = RideRecord(id: "b", startAt: try ms("2026-10-04T14:00:00Z"))
        b.utcOffsetMin = 180
        var c = RideRecord(id: "c", startAt: try ms("2026-10-03T14:00:00Z"))
        c.utcOffsetMin = 180
        var d = RideRecord(id: "d", startAt: try ms("2026-10-04T15:00:00Z"))
        d.kind = "discarded"
        for r in [a, b, c, d] { try store.save(r) }

        let days = try store.ridesByDay()
        XCTAssertEqual(days.map(\.day), ["2026-10-04", "2026-10-03"])
        XCTAssertEqual(days[0].rides.map(\.id), ["b", "a"])
        XCTAssertEqual(days[1].rides.map(\.id), ["c"])
        XCTAssertEqual(try store.rides(includeDiscarded: true).count, 4)
        XCTAssertEqual(try store.rides(limit: 1).map(\.id), ["b"])
    }

    // MARK: delete

    func test_delete_cascadesEverythingOfThatRideOnly() throws {
        let db = try AppDatabase(url: dbURL, build: "t1")
        let store = RideQueries(db)
        for id in ["keep", "drop"] {
            let (ride, samples) = makeRide(id, startAt: id == "keep" ? 1_000 : 2_000, samples: 20)
            try store.save(ride)
            try store.insert(samples: samples)
            try store.insert(chunk: RawChunkRecord(rideId: id, seq: 0, startAt: 0, endAt: 1, kind: "scooter", blob: Data([9])))
            try store.openGap(rideId: id, kind: "gps", startT: 0)
            try store.save(stop: StopRecord(rideId: id, startT: 0, endT: 5_000))
        }
        XCTAssertTrue(try store.delete(rideId: "drop"))
        XCTAssertFalse(try store.delete(rideId: "drop"), "second delete finds nothing")
        XCTAssertNil(try store.ride(id: "drop"))
        XCTAssertEqual(try store.sampleCount(rideId: "drop"), 0)
        XCTAssertTrue(try store.chunks(rideId: "drop").isEmpty)
        XCTAssertTrue(try store.gaps(rideId: "drop").isEmpty)
        XCTAssertTrue(try store.stops(rideId: "drop").isEmpty)
        XCTAssertEqual(try store.sampleCount(rideId: "keep"), 20)
        XCTAssertEqual(try store.chunks(rideId: "keep").count, 1)
        XCTAssertEqual(try store.gaps(rideId: "keep").count, 1)
        XCTAssertEqual(try store.stops(rideId: "keep").count, 1)
    }

    // MARK: update keeps data (the current schema, the frozen 0.4 database)

    func test_frozenDatabase_oldRidesReadable_newRidesAddedAndDeleted_nothingElseChanges() throws {
        let url = try frozenCopy()
        let db = try AppDatabase(url: url, build: "m1-test")
        let store = RideQueries(db)
        let before = try db.rowCounts()

        let old = try store.rides(includeDiscarded: true)
        XCTAssertEqual(old.count, 3, "the three rides of the 0.4 database")
        XCTAssertEqual(old.filter { $0.kind == "shortHop" }.count, 1)
        let first = try XCTUnwrap(old.first { $0.kind == "ride" })
        XCTAssertEqual(first.createdBuild, "0.4-frozen")
        XCTAssertEqual(first.utcOffsetMin, 180)
        XCTAssertNotNil(first.distanceM)
        XCTAssertEqual(try store.sampleCount(rideId: first.id), 60, "old samples readable")
        let oldSamples = try store.samples(rideId: first.id)
        XCTAssertEqual(oldSamples.first?.t, 0)

        // add a new ride with data, close the database, open it again: everything is still there
        let (ride, samples) = makeRide("m1-new", startAt: 1_800_000_000_000, samples: 100)
        try store.save(ride)
        try store.insert(samples: samples)
        let again = try AppDatabase(url: url, build: "m1-test-2")
        let store2 = RideQueries(again)
        XCTAssertEqual(try store2.rides(includeDiscarded: true).count, 4)
        XCTAssertEqual(try store2.sampleCount(rideId: "m1-new"), 100)
        XCTAssertEqual(try store2.sampleCount(rideId: first.id), 60)

        // deleting the new ride puts every table back to the frozen row counts
        XCTAssertTrue(try store2.delete(rideId: "m1-new"))
        let after = try again.rowCounts()
        for (table, count) in before where table != "app_meta" {
            XCTAssertEqual(after[table], count, "table \(table) changed")
        }
        XCTAssertEqual(try store2.rides(includeDiscarded: true).map(\.id).sorted(), old.map(\.id).sorted())
    }

    func test_readOnlyDatabase_refusesWrites() throws {
        let url = try frozenCopy()
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v999-future')")
        }
        let db = try AppDatabase(url: url, build: "m1-test")
        XCTAssertTrue(db.isReadOnly)
        let store = RideQueries(db)
        XCTAssertEqual(try store.rides(includeDiscarded: true).count, 3, "reading still works")
        XCTAssertThrowsError(try store.save(RideRecord(id: "x", startAt: 1)))
        XCTAssertThrowsError(try store.delete(rideId: "x"))
        XCTAssertEqual(try store.rides(includeDiscarded: true).count, 3)
    }

    // MARK: simulator database

    func test_temporaryDatabase_hasTheSameSchema_andNeverTouchesTheRealFile() throws {
        let real = try AppDatabase(url: dbURL, build: "real")
        let realStore = RideQueries(real)
        let (ride, samples) = makeRide("real-ride", startAt: 5_000, samples: 5)
        try realStore.save(ride)
        try realStore.insert(samples: samples)
        let fileBefore = try Data(contentsOf: dbURL)
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let walBefore = try? Data(contentsOf: walURL)

        let temp = try AppDatabase.openTemporary(build: "sim")
        XCTAssertNotEqual(temp.url, real.url)
        XCTAssertTrue(temp.url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(try temp.appliedMigrations(), ["v1"])
        XCTAssertEqual(Set(try temp.rowCounts().keys), Set(Migration0001.tables), "same schema")
        let tempStore = RideQueries(temp)
        var simRide = RideRecord(id: "sim-ride", startAt: 9_000)
        simRide.isSimulated = true
        try tempStore.save(simRide)
        try tempStore.insert(samples: makeRide("sim-ride", startAt: 9_000, samples: 50).1)
        XCTAssertEqual(try tempStore.sampleCount(rideId: "sim-ride"), 50)
        XCTAssertEqual(try tempStore.ride(id: "sim-ride")?.isSimulated, true)

        XCTAssertEqual(try Data(contentsOf: dbURL), fileBefore, "the real database file is byte-for-byte unchanged")
        XCTAssertEqual(try? Data(contentsOf: walURL), walBefore)
        XCTAssertNil(try realStore.ride(id: "sim-ride"))
        XCTAssertEqual(try realStore.rides().count, 1)

        temp.discardTemporary()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path), "discardTemporary never removes the real database")
    }

    func test_discardTemporary_refusesARealFolder() throws {
        let real = try AppDatabase(url: dbURL, build: "real")
        real.discardTemporary()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }
}
