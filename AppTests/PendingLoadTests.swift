import CorckieCore
import Foundation
import GRDB
import XCTest

/// F-02: the Load chosen on Home goes onto the next ride when it starts and then resets.
final class PendingLoadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-load-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "pl")
    }

    private func newRide(_ db: AppDatabase, _ id: String) throws {
        try RideQueries(db).save(RideRecord(id: id, startAt: 1_790_000_000_000))
    }

    private func load(_ db: AppDatabase, _ id: String) throws -> (String?, Double?) {
        try db.writer.read { d in
            let r = try Row.fetchOne(d, sql: "SELECT loadLevel, loadKg FROM ride WHERE id = ?", arguments: [id])
            return (r?["loadLevel"], r?["loadKg"])
        }
    }

    func test_light_isAttachedToTheNextRide_thenResets() throws {
        let db = try open()
        PendingLoad.set(db, LoadChoice(level: .light))
        try newRide(db, "a")
        XCTAssertNotNil(PendingLoad.attach(db, rideId: "a"))
        let a = try load(db, "a")
        XCTAssertEqual(a.0, "light")
        XCTAssertEqual(a.1, 5)
        XCTAssertEqual(PendingLoad.get(db), LoadChoice.empty, "reset to None after the ride")
        try newRide(db, "b")
        XCTAssertNil(PendingLoad.attach(db, rideId: "b"))
        XCTAssertNil(try load(db, "b").0, "the ride after that has no load")
    }

    func test_exactKg_andTheSettingsLevels() throws {
        let db = try open()
        PendingLoad.set(db, LoadChoice(level: .custom, customKg: 7.5))
        try newRide(db, "a")
        PendingLoad.attach(db, rideId: "a")
        XCTAssertEqual(try load(db, "a").1, 7.5)
        // Settings changes the Heavy level: the selector follows it
        SettingsValue.set(db, RiderSettings.heavyKey, "18")
        PendingLoad.set(db, LoadChoice(level: .heavy))
        try newRide(db, "b")
        PendingLoad.attach(db, rideId: "b")
        XCTAssertEqual(try load(db, "b").1, 18)
    }

    func test_none_tagsNothing() throws {
        let db = try open()
        try newRide(db, "a")
        XCTAssertNil(PendingLoad.attach(db, rideId: "a"))
        XCTAssertNil(try load(db, "a").0)
    }
}
