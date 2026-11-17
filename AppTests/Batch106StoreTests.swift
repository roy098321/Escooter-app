import CorckieCore
import Foundation
import GRDB
import XCTest

/// Batch 6 guard tests on made-up places (no real coordinates).
final class Batch106StoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-b106-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t")
    }

    private func addPlace(_ db: AppDatabase, _ id: String, _ name: String?, lat: Double) throws {
        try db.writer.write { d in try PlaceRecord(id: id, name: name, lat: lat, lon: 20, createdAt: 1).insert(d) }
    }

    /// N6-1 (B95): a removed place leaves Where to, Places, map pins and new-ride matching, stays for history, and Put back returns it.
    func test_N6_1_removedPlace_leavesEverydayLists_keepsHistory_putBackReturnsIt() throws {
        let db = try open()
        try addPlace(db, "p1", "Gym", lat: 10.02)
        try addPlace(db, "p2", "Library", lat: 10.05)
        try db.writer.write { d in
            try RouteRecord(id: "r1", fromPlaceId: "p2", toPlaceId: "p1", name: nil, usualDistanceM: 3_000, sizeClass: nil, state: "saved", createdAt: 1).insert(d)
        }
        try QuickDialLoader.writePins(["p1": 0], database: db)

        try PlaceService.remove(placeId: "p1", database: db, nowMs: 5)
        let store = RouteQueries(db)
        XCTAssertEqual(try store.activePlaces().map(\.id), ["p2"])
        XCTAssertEqual(try store.removedPlaces().map(\.id), ["p1"])
        XCTAssertEqual(try store.place(id: "p1")?.name, "Gym", "history keeps the place and its name")
        XCTAssertEqual(try store.places().count, 2, "no row is ever dropped")
        XCTAssertNil(QuickDialLoader.pins(db)["p1"], "it leaves the Home quick dial")
        let dial = QuickDialLoader.load(database: db, routeChips: [], slots: 3, from: nil)
        XCTAssertFalse(dial.chips.contains { $0.routeId == "place:p1" }, "not a destination any more")
        XCTAssertFalse(PlaceMapLoader.items(database: db).contains { $0.id == "p1" }, "not on Places or the maps")
        let book = try RouteProcessor.loadBook(store)
        XCTAssertFalse(book.places.contains { $0.id == "p1" }, "new rides are not matched to it")
        XCTAssertFalse(book.routes.contains { $0.id == "r1" }, "nor to routes ending there")
        XCTAssertNotNil(try store.route(id: "r1"), "its route stays for past rides")

        try PlaceService.putBack(placeId: "p1", database: db)
        XCTAssertEqual(Set(try store.activePlaces().map(\.id)), ["p1", "p2"])
        XCTAssertTrue(try store.removedPlaces().isEmpty)
        XCTAssertTrue(try RouteProcessor.loadBook(store).places.contains { $0.id == "p1" })
    }
}
