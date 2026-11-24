import CorckieCore
import Foundation
import GRDB
import XCTest

/// Hotfix 111.291126.07 (audit A1): the odometer the Scooter tab, maintenance and the service report read is the ACTIVE scooter's.
/// Synthetic data only.
final class Hotfix07StoreTests: XCTestCase {
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

    func test_A1_odometer_neverBorrowsAnotherScootersKm() throws {
        let db = try makeDB()
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO scooter (id, name, firstSeenAt, forgottenAt) VALUES ('old', 'Synthetic A', 1, 5)")
            try d.execute(sql: "INSERT INTO scooter (id, name, firstSeenAt) VALUES ('new', 'Synthetic B', 6)")
            // the old scooter sends an odometer; the new one sends none (its rides have no km)
            try d.execute(sql: "INSERT INTO ride (id, scooterId, startAt, odoEndKm) VALUES ('r-old', 'old', 1000, 777.7)")
            try d.execute(sql: "INSERT INTO ride (id, scooterId, startAt) VALUES ('r-new', 'new', 2000)")
        }
        XCTAssertNil(try MaintenanceQueries(db).odometerKm(), "the new scooter has no km of its own")

        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO ride (id, scooterId, startAt, odoEndKm) VALUES ('r-new2', 'new', 3000, 12.5)")
        }
        XCTAssertEqual(try MaintenanceQueries(db).odometerKm(), 12.5)
    }

    func test_A1_odometer_untaggedOlderRidesStillCount() throws {
        let db = try makeDB()
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO ride (id, startAt, odoEndKm) VALUES ('r1', 1000, 321.0)")
        }
        XCTAssertEqual(try MaintenanceQueries(db).odometerKm(), 321.0)
    }
}
