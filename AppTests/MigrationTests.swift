import Foundation
import GRDB
import XCTest

/// TESTING §1 layer 4 · DATA_MODEL §4 V1–V7: every earlier milestone's database upgrades
/// with no row lost. App/Store is compiled straight into this test bundle (no app host),
/// so the tests run on the iOS Simulator without Bluetooth or location side effects.
final class MigrationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func frozenCopy(_ name: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: MigrationTests.self).url(forResource: name, withExtension: "sqlite"),
                                   "\(name).sqlite missing from the test bundle")
        let target = folder.appendingPathComponent("corckie.sqlite")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// V1: a fresh install creates every table of DATA_MODEL §2 and the app_meta row.
    func test_V1_freshInstall_createsTheWholeSchema() throws {
        let db = try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "test-1")
        XCTAssertFalse(db.isReadOnly)
        XCTAssertNil(db.preMigrationCopy, "nothing to back up on a fresh install")
        XCTAssertEqual(try db.appliedMigrations(), ["v1"])
        let counts = try db.rowCounts()
        XCTAssertEqual(Set(counts.keys), Set(Migration0001.tables))
        XCTAssertEqual(counts["app_meta"], 1)
        XCTAssertEqual(db.meta?.createdBuild, "test-1")
        XCTAssertEqual(db.meta?.launchCount, 1)
    }

    /// V7: the frozen foundation database (0.4) opens in this build with no row lost.
    func test_V7_frozenFoundationDatabase_keepsEveryRow() throws {
        let url = try frozenCopy("p4-foundation")
        let before = try DatabaseQueue(path: url.path).read { db -> [String: Int] in
            var counts: [String: Int] = [:]
            for table in Migration0001.tables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return counts
        }
        XCTAssertTrue(before.values.allSatisfy { $0 > 0 }, "the frozen database should fill every table")

        let db = try AppDatabase(url: url, build: "test-2")
        let after = try db.rowCounts()
        for (table, count) in before {
            XCTAssertGreaterThanOrEqual(after[table] ?? 0, count, "rows lost in \(table)")
        }
        XCTAssertEqual(db.meta?.installId, "00000000-0000-0000-0000-00000000F00D", "same install, data kept")
        XCTAssertEqual(db.meta?.createdBuild, "0.4-frozen")
        XCTAssertEqual(db.meta?.lastBuild, "test-2")
        XCTAssertEqual(db.meta?.launchCount, 4)
    }

    /// V3: before migrating existing data, a copy is written; it is removed after the next good launch.
    func test_V3_backupBeforeMigrate_thenCleanedUp() throws {
        let url = try frozenCopy("p4-foundation")
        var migrator = AppDatabase.makeMigrator()
        migrator.registerMigration("v2-test") { db in
            try db.execute(sql: "ALTER TABLE ride ADD COLUMN testColumn TEXT")
        }
        let db = try AppDatabase(url: url, build: "test-3", migrator: migrator)
        let copy = try XCTUnwrap(db.preMigrationCopy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(db.migratedNow, ["v2-test"])
        let copiedRides = try DatabaseQueue(path: copy.path).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") }
        XCTAssertEqual(copiedRides, 3)

        let next = try AppDatabase(url: url, build: "test-4", migrator: migrator)
        XCTAssertNil(next.preMigrationCopy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "kept only until the next successful launch")
    }

    /// V4: a failing migration throws and leaves the data as it was (migrations run in a transaction).
    func test_V4_failedMigration_stopsAndKeepsData() throws {
        let url = try frozenCopy("p4-foundation")
        var migrator = AppDatabase.makeMigrator()
        migrator.registerMigration("v2-broken") { db in
            try db.execute(sql: "DELETE FROM ride")
            try db.execute(sql: "THIS IS NOT SQL")
        }
        XCTAssertThrowsError(try AppDatabase(url: url, build: "test-5", migrator: migrator))
        let rides = try DatabaseQueue(path: url.path).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") }
        XCTAssertEqual(rides, 3)
    }

    /// V6: a database from a newer build opens read-only.
    func test_V6_newerDatabase_opensReadOnly() throws {
        let url = try frozenCopy("p4-foundation")
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v999-future')")
        }
        let db = try AppDatabase(url: url, build: "test-6")
        XCTAssertTrue(db.isReadOnly)
        XCTAssertThrowsError(try db.writer.write { try $0.execute(sql: "DELETE FROM ride") })
    }
}
