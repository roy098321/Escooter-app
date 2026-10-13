import Foundation
import GRDB
import XCTest

/// T-00 part 1: ride notes, one-tap feedback, their export texts, and the v2 migration keeping data.
final class FieldKitStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-fk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func openDB() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "fk-test")
    }

    private func addRide(_ db: AppDatabase, id: String, startAt: Int64) throws {
        var ride = RideRecord(id: id, startAt: startAt)
        ride.distanceM = 4200
        ride.totalS = 900
        ride.startRestPct = 80
        ride.endRestPct = 74
        try RideQueries(db).save(ride)
    }

    func test_note_isStored_editedLater_andRemovedWhenEmpty() throws {
        let db = try openDB()
        try addRide(db, id: "r1", startAt: 1_000_000)
        let store = FieldKitQueries(db)
        XCTAssertNil(try store.note(rideId: "r1"))
        try store.setNote(rideId: "r1", text: "  Windy at the bridge  ")
        XCTAssertEqual(try store.note(rideId: "r1"), "Windy at the bridge")
        try store.setNote(rideId: "r1", text: "Windy at the bridge, scooter felt slow")
        XCTAssertEqual(try store.note(rideId: "r1"), "Windy at the bridge, scooter felt slow")
        try store.setNote(rideId: "r1", text: "   ")
        XCTAssertNil(try store.note(rideId: "r1"))
    }

    func test_rideNotesText_hasRouteDistanceTimeBatteryAndNote_noIds() throws {
        let db = try openDB()
        try addRide(db, id: "secret-ride-id", startAt: 1_800_000_000_000)
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO route (id, name, state) VALUES ('rt1', 'Home to work', 'saved')")
            try d.execute(sql: "UPDATE ride SET routeId = 'rt1' WHERE id = 'secret-ride-id'")
        }
        try FieldKitQueries(db).setNote(rideId: "secret-ride-id", text: "Brakes squeaked")
        let text = try FieldKitQueries(db).rideNotesText()
        XCTAssertTrue(text.contains("1 notes"))
        XCTAssertTrue(text.contains("route: Home to work"))
        XCTAssertTrue(text.contains("4.20 km"))
        XCTAssertTrue(text.contains("15 min"))
        XCTAssertTrue(text.contains("battery used 6% (80→74%)"))
        XCTAssertTrue(text.contains("Note: Brakes squeaked"))
        XCTAssertFalse(text.contains("secret-ride-id"))
    }

    func test_feedback_isReplacedPerSubject_andExported() throws {
        let db = try openDB()
        let store = FieldKitQueries(db)
        try store.setFeedback(kind: "end", subjectId: "r1", subjectText: nil, verdict: 1)
        XCTAssertEqual(try store.verdict(kind: "end", subjectId: "r1"), 1)
        try store.setFeedback(kind: "end", subjectId: "r1", subjectText: nil, verdict: -1, reason: "Ended too early", note: "I was at the lights")
        try store.setFeedback(kind: "insight", subjectId: "i1", subjectText: "Windy rides use more battery", verdict: 1)
        XCTAssertEqual(try store.allFeedback().count, 2, "answering again replaces, not adds")
        let text = try store.feedbackText()
        XCTAssertTrue(text.contains("2 answers"))
        XCTAssertTrue(text.contains("end · down · wrong: Ended too early · note: I was at the lights"))
        XCTAssertTrue(text.contains("insight · up · \"Windy rides use more battery\""))
        XCTAssertTrue(FieldKitQueries.reasons(for: "distance").contains("Too long"))
    }

    func test_readOnlyDatabase_refusesWrites() throws {
        let db = try openDB()
        try addRide(db, id: "r1", startAt: 1)
        try db.writer.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('v999-future')") }
        let future = try openDB()
        XCTAssertTrue(future.isReadOnly)
        XCTAssertThrowsError(try FieldKitQueries(future).setNote(rideId: "r1", text: "x"))
    }

    /// Update keeps data: the frozen 0.4 database gets the v2 tables and keeps every row.
    func test_migrationV2_onFrozenDatabase_keepsRows_andAddsTables() throws {
        let source = try XCTUnwrap(Bundle(for: FieldKitStoreTests.self).url(forResource: "p4-foundation", withExtension: "sqlite"))
        let url = folder.appendingPathComponent("corckie.sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        let rides = try DatabaseQueue(path: url.path).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") }
        let db = try AppDatabase(url: url, build: "fk-test")
        XCTAssertEqual(db.migratedNow, ["v2", "v3", "v4"])
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") }, rides)
        for table in Migration0002.tables {
            XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }, 0)
        }
        let firstRide = try XCTUnwrap(try RideQueries(db).rides().first)
        try FieldKitQueries(db).setNote(rideId: firstRide.id, text: "kept")
        let again = try AppDatabase(url: url, build: "fk-test-2")
        XCTAssertEqual(try FieldKitQueries(again).note(rideId: firstRide.id), "kept", "note survives the next update")
    }

    /// A ride deleted takes its note with it (no orphan text in the export).
    func test_deletingRide_removesItsNote() throws {
        let db = try openDB()
        try addRide(db, id: "r1", startAt: 1)
        try FieldKitQueries(db).setNote(rideId: "r1", text: "gone soon")
        try db.writer.write { try $0.execute(sql: "DELETE FROM ride WHERE id = 'r1'") }
        XCTAssertNil(try FieldKitQueries(db).note(rideId: "r1"))
    }
}
