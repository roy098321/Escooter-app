import CorckieCore
import Foundation
import GRDB
import XCTest

/// D2 section 7 guard: every table and column in the real schema has a category in `DataMap`.
/// Adding data without deciding whether it is the rider's or the scooter's fails this test.
/// Also covers Start fresh (synthetic data only).
final class DataMapGuardTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "test-fresh")
    }

    func test_everyTableAndColumnIsInTheDataMap() throws {
        let db = try makeDB()
        try db.writer.read { d in
            let tables = try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'")
            for table in tables {
                XCTAssertNotNil(DataMap.category(table: table), "table \(table) is not in DataMap: decide rider or scooter")
                guard DataMap.isMixed(table) else { continue }
                let columns = try String.fetchAll(d, sql: "SELECT name FROM pragma_table_info('\(table)')")
                for column in columns {
                    XCTAssertNotNil(DataMap.category(table: table, column: column), "column \(table).\(column) is not in DataMap")
                }
                for listed in DataMap.mixedColumns[table]!.keys {
                    XCTAssertTrue(columns.contains(listed), "DataMap lists \(table).\(listed) but the schema has no such column")
                }
            }
            for listed in DataMap.tables.keys {
                XCTAssertTrue(tables.contains(listed), "DataMap lists table \(listed) that does not exist")
            }
        }
    }

    private func seed(_ db: AppDatabase) throws {
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO scooter (id, name, firstSeenAt) VALUES ('old', 'G2', 1)")
            try d.execute(sql: "INSERT INTO ride (id, scooterId, startAt, usedPct) VALUES ('r1', 'old', 1000, 12.0)")
            try d.execute(sql: "INSERT INTO place (id, name, lat, lon) VALUES ('p1', 'Synthetic', 1.0, 2.0)")
            try d.execute(sql: "INSERT INTO calibration (id, scooterId, packAh) VALUES ('c1', 'old', 16)")
            try d.execute(sql: "INSERT INTO prediction (kind, madeAt, predicted) VALUES ('range', 1, 10)")
            try d.execute(sql: "INSERT INTO setting (key, json) VALUES ('battery.packAh', '15')")
            try d.execute(sql: "INSERT INTO setting (key, json) VALUES ('rider.loadKg', '80')")
            try d.execute(sql: "INSERT INTO error_log (at, level, source, message) VALUES (1, 'info', 'test', 'kept')")
        }
    }

    private func count(_ db: AppDatabase, _ table: String) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0 }
    }

    func test_startFresh_blank_clearsRiderScooterAndAccuracy_keepsLogs() throws {
        let db = try makeDB()
        try seed(db)
        let backup = try StartFresh.localBackup(db, nowMs: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        try StartFresh.reset(db, keepRider: false, nowMs: 5)
        for table in ["ride", "place", "scooter", "calibration", "prediction"] {
            XCTAssertEqual(try count(db, table), 0, table)
        }
        XCTAssertEqual(try count(db, "error_log"), 1)
        XCTAssertNil(try db.writer.read { try String.fetchOne($0, sql: "SELECT json FROM setting WHERE key = 'rider.loadKg'") })
        XCTAssertEqual(try db.writer.read { try String.fetchOne($0, sql: "SELECT json FROM setting WHERE key = ?", arguments: [StartFresh.keptRiderKey]) }, "0")
    }

    func test_startFresh_keepRider_keepsRidesAndPlacesButTagsTheOldScooter() throws {
        let db = try makeDB()
        try seed(db)
        try StartFresh.reset(db, keepRider: true, nowMs: 7)
        XCTAssertEqual(try count(db, "ride"), 1)
        XCTAssertEqual(try count(db, "place"), 1)
        XCTAssertEqual(try count(db, "calibration"), 0)
        XCTAssertEqual(try count(db, "prediction"), 0)
        let forgotten = try db.writer.read { try Int64.fetchOne($0, sql: "SELECT forgottenAt FROM scooter WHERE id = 'old'") }
        XCTAssertEqual(forgotten, 7, "the old scooter row stays, marked forgotten")
        XCTAssertNil(try db.writer.read { try String.fetchOne($0, sql: "SELECT json FROM setting WHERE key = 'battery.packAh'") })
        XCTAssertEqual(try db.writer.read { try String.fetchOne($0, sql: "SELECT json FROM setting WHERE key = 'rider.loadKg'") }, "80")
    }

    /// The battery door: after "keep rider info" the old scooter's rides stay for times and routes but not for battery math.
    func test_batteryDoor_skipsRidesOfTheOldScooter() throws {
        let db = try makeDB()
        try seed(db)
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO ride (id, scooterId, startAt, usedPct) VALUES ('untagged', NULL, 2000, 8.0)")
        }
        let door = "SELECT COUNT(*) FROM ride WHERE \(BatteryDoor.rides())"
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: door) }, 2, "before: both count")
        try StartFresh.reset(db, keepRider: true, nowMs: 9)
        XCTAssertEqual(try count(db, "ride"), 2, "rides stay for times and routes")
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: door) }, 0, "old scooter's rides never count for battery")
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO scooter (id, name, firstSeenAt) VALUES ('new', 'G2', 10)")
            try d.execute(sql: "INSERT INTO ride (id, scooterId, startAt, usedPct) VALUES ('r-new', 'new', 3000, 5.0)")
        }
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: door) }, 1, "the new scooter's ride counts")
    }
}
