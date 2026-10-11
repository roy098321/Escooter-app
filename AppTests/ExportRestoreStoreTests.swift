import CorckieCore
import GRDB
import XCTest

/// M5-05 / M5-07: Export everything, Restore (merge by ride), Delete all data, raw data retention on the real schema.
final class ExportRestoreStoreTests: XCTestCase {
    private var a: AppDatabase!
    private var b: AppDatabase!
    private var folder: URL!
    private let t0: Int64 = 1_790_000_000_000

    override func setUpWithError() throws {
        a = try AppDatabase.openTemporary(build: "test")
        b = try AppDatabase.openTemporary(build: "test")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RideToolsSeed.ride(a, id: "R1", startAt: t0)
        try RideToolsSeed.ride(a, id: "R2", startAt: t0 + 5 * 3_600_000, n: 60)
        try RideToolsSeed.ride(a, id: "R3", startAt: t0 + 86_400_000)
        try a.writer.write { d in
            try d.execute(sql: "INSERT INTO place (id, name, lat, lon, radiusM, canCharge, createdAt) VALUES ('p1', 'Home', 10, -30, 50, 0, 1)")
        }
        try RideQueries(a).setSetting(key: "unit.test", json: "7")
    }

    override func tearDownWithError() throws {
        a.discardTemporary()
        b.discardTemporary()
        try? FileManager.default.removeItem(at: folder)
    }

    private func count(_ db: AppDatabase, _ table: String) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private func exportFile() throws -> URL {
        let url = folder.appendingPathComponent("export.json")
        let result = try ExportAll.write(a, to: url, build: "test", nowMs: t0)
        XCTAssertEqual(result.rides, 3)
        XCTAssertGreaterThan(result.bytes, 1_000)
        return url
    }

    func testExportThenRestoreIntoAnEmptyPhone() throws {
        let report = try RestoreService.restore(b, from: try exportFile())
        XCTAssertEqual(report.ridesAdded, 3)
        XCTAssertEqual(report.ridesSkipped, 0)
        XCTAssertEqual(report.ridesFailed, 0)
        XCTAssertEqual(report.source, "export file")
        XCTAssertEqual(try count(b, "ride"), 3)
        XCTAssertEqual(try count(b, "ride_sample"), 260)
        XCTAssertEqual(try count(b, "place"), 1)
        XCTAssertEqual(try RideQueries(b).setting(key: "unit.test"), "7")
        let distanceA = try XCTUnwrap(RideQueries(a).ride(id: "R1")?.distanceM)
        let distanceB = try XCTUnwrap(RideQueries(b).ride(id: "R1")?.distanceM)
        XCTAssertEqual(distanceA, distanceB, accuracy: 0.0001)
    }

    func testRestoringTwiceNeverDuplicatesAndNeverOverwrites() throws {
        let url = try exportFile()
        _ = try RestoreService.restore(b, from: url)
        try b.writer.write { try $0.execute(sql: "UPDATE ride SET usedPct = 99 WHERE id = 'R1'") }
        try RideQueries(b).setSetting(key: "unit.test", json: "changed")
        let again = try RestoreService.restore(b, from: url)
        XCTAssertEqual(again.ridesAdded, 0)
        XCTAssertEqual(again.ridesSkipped, 3)
        XCTAssertEqual(try count(b, "ride"), 3)
        XCTAssertEqual(try count(b, "ride_sample"), 260)
        XCTAssertEqual(try count(b, "place"), 1)
        XCTAssertEqual(try RideQueries(b).ride(id: "R1")?.usedPct, 99)
        XCTAssertEqual(try RideQueries(b).setting(key: "unit.test"), "changed")
    }

    func testARideAlreadyThereUnderAnotherIdIsSkipped() throws {
        try RideToolsSeed.ride(b, id: "OTHER-ID", startAt: t0)             // the same ride as R1 (same start, same distance)
        let report = try RestoreService.restore(b, from: try exportFile())
        XCTAssertEqual(report.ridesAdded, 2)
        XCTAssertEqual(report.ridesSkipped, 1)
        XCTAssertEqual(try count(b, "ride"), 3)
    }

    func testRestoreFromAFullBackupSnapshot() throws {
        let snap = folder.appendingPathComponent("snap.sqlite")
        try a.writeSnapshot(to: snap)
        let report = try RestoreService.restore(b, data: try Data(contentsOf: snap))
        XCTAssertEqual(report.source, "full backup")
        XCTAssertEqual(report.ridesAdded, 3)
        XCTAssertEqual(try count(b, "ride_sample"), 260)
    }

    func testRestoreFromAGzippedFile() throws {
        let plain = try Data(contentsOf: try exportFile())
        let deflated = try (plain as NSData).compressed(using: .zlib) as Data
        let gz = Data(GzipFrame.wrap(deflated: [UInt8](deflated), original: [UInt8](plain)))
        XCTAssertTrue(GzipReader.isGzip(gz))
        let report = try RestoreService.restore(b, data: gz)
        XCTAssertEqual(report.ridesAdded, 3)
    }

    private struct Delta: Encodable {
        var app = "CorckieApp"
        var ride: RideRecord
        var samples: [RideSampleRecord]
        var stops: [StopRecord]
        var gaps: [GapRecord]
        var chunks: [RawChunkRecord]
    }

    func testRestoreFromARideFileOfTheBackupFolder() throws {
        let q = RideQueries(a)
        let delta = Delta(ride: try XCTUnwrap(q.ride(id: "R2")), samples: try q.samples(rideId: "R2"), stops: [],
                          gaps: [GapRecord(id: 5, rideId: "R2", kind: "scooter", startT: 1_000, endT: 2_000)], chunks: [])
        let data = try JSONEncoder().encode(delta)
        let first = try RestoreService.restore(b, data: data)
        XCTAssertEqual(first.source, "ride file")
        XCTAssertEqual(first.ridesAdded, 1)
        XCTAssertEqual(try count(b, "ride_sample"), 60)
        XCTAssertEqual(try count(b, "gap"), 1)
        let second = try RestoreService.restore(b, data: data)
        XCTAssertEqual(second.ridesAdded, 0)
        XCTAssertEqual(second.ridesSkipped, 1)
        XCTAssertEqual(try count(b, "gap"), 1)
    }

    func testSimulatedRidesAreNotExported() throws {
        try RideToolsSeed.ride(a, id: "SIM", startAt: t0 + 9 * 86_400_000, simulated: true)
        let file = try ExportAll.make(a, build: "test", nowMs: t0)
        XCTAssertEqual(file.rides.count, 3)
        XCTAssertFalse(file.rides.contains { $0.rideId == "SIM" })
    }

    func testMergeUndoNoteIsNotExported() throws {
        try RideQueries(a).setSetting(key: "merge.undo", json: "{}")
        let file = try ExportAll.make(a, build: "test", nowMs: t0)
        let setting = try XCTUnwrap(file.tables.first { $0.name == "setting" })
        let keyIndex = setting.columns.firstIndex(of: "key") ?? 0
        let keys = setting.rows.compactMap { $0[keyIndex].text }
        XCTAssertTrue(keys.contains("unit.test"))
        XCTAssertFalse(keys.contains("merge.undo"))
    }

    func testAnUnknownFileIsRefused() {
        XCTAssertThrowsError(try RestoreService.restore(b, data: Data("hello".utf8)))
        XCTAssertThrowsError(try RestoreService.restore(b, data: Data()))
    }

    func testDeleteAllKeepsSettings() throws {
        try DeleteAllData.run(a)
        XCTAssertEqual(try count(a, "ride"), 0)
        XCTAssertEqual(try count(a, "ride_sample"), 0)
        XCTAssertEqual(try count(a, "place"), 0)
        XCTAssertEqual(try RideQueries(a).setting(key: "unit.test"), "7")
    }

    func testFileName() {
        XCTAssertEqual(ExportAll.fileName(nowMs: t0, utcOffsetMin: 180), "CorckieApp export 2026-09-21.json")
    }

    // MARK: Retention (M5-07)

    private func addChunk(_ ride: String, seq: Int, kind: String, endAt: Int64) throws {
        try RideQueries(a).insert(chunk: RawChunkRecord(rideId: ride, seq: seq, startAt: endAt - 30_000, endAt: endAt, kind: kind, blob: Data([1, 2, 3, 4])))
    }

    func testRetentionDeletesOldRawChunksOnlyAndKeepsEnergyAndSummaries() throws {
        let now = t0 + 200 * 86_400_000
        let day: Int64 = 86_400_000
        try addChunk("R1", seq: 0, kind: "scooter", endAt: now - 120 * day)     // old: goes
        try addChunk("R1", seq: 1, kind: "phone", endAt: now - 100 * day)       // old: goes
        try addChunk("R1", seq: 2, kind: "energy", endAt: now - 150 * day)      // old but energy: stays
        try addChunk("R2", seq: 0, kind: "scooter", endAt: now - 10 * day)      // recent: stays
        XCTAssertEqual(RetentionService.current(a), .days90)
        let deleted = try RetentionService.run(a, nowMs: now)
        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(try count(a, "raw_chunk"), 2)
        XCTAssertEqual(try count(a, "ride"), 3)
        XCTAssertEqual(try count(a, "ride_sample"), 260)
        XCTAssertNotNil(try RideQueries(a).ride(id: "R1")?.distanceM)
        XCTAssertEqual(try RetentionService.run(a, nowMs: now), 0)
    }

    func testRetentionSettingChangesWhatIsKept() throws {
        let now = t0 + 400 * 86_400_000
        let day: Int64 = 86_400_000
        try addChunk("R1", seq: 0, kind: "scooter", endAt: now - 200 * day)
        try addChunk("R1", seq: 1, kind: "scooter", endAt: now - 400 * day)
        RetentionService.set(a, .forever, nowMs: now)
        XCTAssertEqual(RetentionService.current(a), .forever)
        XCTAssertEqual(try count(a, "raw_chunk"), 2)
        RetentionService.set(a, .year, nowMs: now)
        XCTAssertEqual(try count(a, "raw_chunk"), 1)                           // 400 days old goes, 200 days stays
        RetentionService.set(a, .days90, nowMs: now)
        XCTAssertEqual(try count(a, "raw_chunk"), 0)
        XCTAssertEqual(try count(a, "ride"), 3)
        XCTAssertEqual(RetentionService.usage(a).chunks, 0)
    }
}
