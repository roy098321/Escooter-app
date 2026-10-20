import CorckieCore
import CorckieSim
import Foundation
import GRDB
import XCTest

/// P6-4 chunk 2: places as destinations and the quick dial (F-29, B31), and the odometer gap store (B35), on made-up places and rides.
final class QuickDialStoreTests: XCTestCase {
    private var folder: URL!
    private let base: Int64 = 1_790_000_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-quickdial-tests-\(UUID().uuidString)")
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

    func test_namedPlaceWithoutARouteIsADestination() throws {
        let db = try open()
        try addPlace(db, "p1", "Gym", lat: 10.02)
        try addPlace(db, "p2", nil, lat: 10.05)
        let loaded = QuickDialLoader.load(database: db, routeChips: [], slots: 3, from: GeoPoint(lat: 10, lon: 20), nowMs: base, utcOffsetMin: 0)
        XCTAssertEqual(loaded.chips.map(\.routeId), ["place:p1"])
        XCTAssertNil(loaded.chips.first?.timeText, "B44: no ride there, no time (no straight-line guess)")
        XCTAssertEqual(loaded.chips.first?.note, "no rides there yet")
        XCTAssertEqual(loaded.chips.first?.here, false)
        XCTAssertEqual(QuickDialLoader.placeId(fromKey: "place:p1"), "p1")
        XCTAssertNil(QuickDialLoader.placeId(fromKey: "route-1"))
        let none = QuickDialLoader.load(database: db, routeChips: [], slots: 3, from: nil)
        XCTAssertNil(none.chips.first?.timeText)
        // B46: standing inside the circle makes the place "here"
        let atGym = QuickDialLoader.load(database: db, routeChips: [], slots: 3, from: GeoPoint(lat: 10.02, lon: 20), nowMs: base, utcOffsetMin: 0)
        XCTAssertEqual(atGym.chips.first?.here, true)
        XCTAssertEqual(atGym.rows.first?.here, true)
    }

    /// B44 / B45 (P6-5): a place's time comes only from rides that ended there
    func test_placeTimeComesOnlyFromRidesThatEndedThere() throws {
        let db = try open()
        try addPlace(db, "p1", "Old workplace", lat: 10.05)
        let none = QuickDialLoader.load(database: db, routeChips: [], slots: 3, from: nil, nowMs: base, utcOffsetMin: 0)
        XCTAssertEqual(none.chips.first?.note, "no rides there yet")
        _ = try RouteFixtures.insertRide(db, id: "r1", path: SyntheticRoutes.main, startAt: base - 2 * 86_400_000, simulated: false)
        try RouteQueries(db).setPlaces(rideId: "r1", startPlaceId: nil, endPlaceId: "p1")
        let one = QuickDialLoader.load(database: db, routeChips: [], slots: 3, from: nil, nowMs: base, utcOffsetMin: 0)
        XCTAssertEqual(one.chips.first?.note, "1 ride there \u{00B7} estimate after 2")
        _ = try RouteFixtures.insertRide(db, id: "r2", path: SyntheticRoutes.main, startAt: base - 86_400_000, simulated: false)
        try RouteQueries(db).setPlaces(rideId: "r2", startPlaceId: nil, endPlaceId: "p1")
        let two = QuickDialLoader.load(database: db, routeChips: [], slots: 3, from: nil, nowMs: base, utcOffsetMin: 0)
        XCTAssertNotNil(two.chips.first?.timeText)
        XCTAssertNil(two.chips.first?.note)
        XCTAssertEqual(two.rows.first?.timeText, two.chips.first?.timeText)
    }

    func test_pinsAreWrittenAndReadBackInOrder() throws {
        let db = try open()
        try addPlace(db, "a", "A", lat: 10.01)
        try addPlace(db, "b", "B", lat: 10.02)
        try QuickDialLoader.writePins(["b": 1, "a": 2], database: db)
        XCTAssertEqual(QuickDialLoader.pins(db), ["b": 1, "a": 2])
        try QuickDialLoader.writePins(["a": 1], database: db)
        XCTAssertEqual(QuickDialLoader.pins(db), ["a": 1])
    }

    func test_iconAndSlotAreStoredPerPlace() throws {
        let db = try open()
        try addPlace(db, "p1", "Maya's house", lat: 10.01)
        try QuickDialLoader.setIcon(.letters("M"), placeId: "p1", database: db)
        try QuickDialLoader.setPin(2, placeId: "p1", database: db)
        XCTAssertEqual(QuickDialLoader.icons(db)["p1"], .letters("M"))
        XCTAssertEqual(QuickDialLoader.pins(db)["p1"], 2)
        let loaded = QuickDialLoader.load(database: db, routeChips: [], slots: 3, from: nil)
        XCTAssertEqual(loaded.items.map(\.key), ["place:p1"])
        XCTAssertEqual(loaded.items.first?.icon, .letters("M"))
        try QuickDialLoader.setIcon(.symbol("house"), placeId: "p1", database: db)
        XCTAssertEqual(QuickDialLoader.icons(db)["p1"], .symbol("house"))
        try QuickDialLoader.setPin(nil, placeId: "p1", database: db)
        try QuickDialLoader.setIcon(nil, placeId: "p1", database: db)
        XCTAssertTrue(QuickDialLoader.pins(db).isEmpty)
        XCTAssertTrue(QuickDialLoader.icons(db).isEmpty)
    }

    func test_gapIsFoundOnceFromTheLastRideEndOdometer() throws {
        let db = try open()
        _ = try RouteFixtures.insertRide(db, id: "r1", path: SyntheticRoutes.main, startAt: base, simulated: false)
        XCTAssertNil(GapStore.detect(db, connectOdoKm: 500, nowMs: base), "no stored end odometer, no verdict")
        try db.writer.write { d in try d.execute(sql: "UPDATE ride SET odoEndKm = 100 WHERE id = 'r1'") }
        XCTAssertNil(GapStore.detect(db, connectOdoKm: 100.2, nowMs: base))
        let gap = try XCTUnwrap(GapStore.detect(db, connectOdoKm: 104.2, nowMs: base + 1))
        XCTAssertEqual(gap.km, 4.2, accuracy: 1e-9)
        XCTAssertNil(GapStore.detect(db, connectOdoKm: 104.2, nowMs: base + 2))
        XCTAssertEqual(GapStore.all(db).count, 1)
        XCTAssertEqual(GapStore.all(db).first?.km ?? 0, 4.2, accuracy: 1e-9)
    }
}
