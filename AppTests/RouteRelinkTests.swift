import CorckieCore
import CorckieSim
import Foundation
import GRDB
import XCTest

/// B24 (T-04): every ride gets its start / end place from the place circles, the way back of a route is its own route after one
/// trip, and the one-off re-link pass gives stored rides the same links without losing a row (a9). Made-up rides on the
/// synthetic map only.
final class RouteRelinkTests: XCTestCase {
    private var folder: URL!
    private let day: Int64 = 86_400_000
    private let base: Int64 = 1_790_000_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-relink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t")
    }

    private var back: [SyntheticRoutes.XY] { SyntheticRoutes.reversed(SyntheticRoutes.main) }
    /// Somewhere 3 km away, then home (no place at the start)
    private var toHome: [SyntheticRoutes.XY] { SyntheticRoutes.offset(SyntheticRoutes.loop, by: (x: 3_000, y: 0)) + [(x: 0, y: 0)] }

    @discardableResult
    private func ride(_ db: AppDatabase, _ id: String, _ path: [SyntheticRoutes.XY], at k: Double) throws -> RouteProcessResult {
        try RouteFixtures.insertRide(db, id: id, path: path, startAt: base + Int64(k * Double(day)))
        return try XCTUnwrap(try RouteProcessor.process(rideId: id, database: db))
    }

    func test_B24_atRideClose_wayBackIsOffered_andEveryRideHasItsPlaces() throws {
        let db = try open()
        let store = RouteQueries(db)
        try ride(db, "a", SyntheticRoutes.main, at: 0)
        let b = try ride(db, "b", SyntheticRoutes.main, at: 1)
        let ab = try XCTUnwrap(store.route(id: try XCTUnwrap(b.routeId)))
        let home = try XCTUnwrap(ab.fromPlaceId), work = try XCTUnwrap(ab.toPlaceId)

        let c = try ride(db, "c", back, at: 1.4)
        XCTAssertEqual(c.outcome, .suggested, "the way back is a route after its first trip")
        XCTAssertNotEqual(c.routeId, ab.id)
        XCTAssertEqual(c.ridesOnRoute, 1)
        XCTAssertEqual(try store.link(rideId: "c")?.startPlaceId, work)
        XCTAssertEqual(try store.link(rideId: "c")?.endPlaceId, home)
        let offer = try XCTUnwrap(RouteService.offer(rideId: "c", database: db))
        XCTAssertEqual(offer.headline, "Save as route?")
        XCTAssertTrue(offer.detail.contains("way back"), offer.detail)
        XCTAssertEqual(try store.counts().places, 2)

        // more trips back count on that route (the estimates need 3 / 5)
        try ride(db, "d", back, at: 2.4)
        let e = try ride(db, "e", back, at: 3.4)
        XCTAssertEqual(e.routeId, c.routeId)
        XCTAssertEqual(e.ridesOnRoute, 3)

        // a ride on no route still ends at home
        let f = try ride(db, "f", toHome, at: 4)
        XCTAssertNil(f.routeId)
        XCTAssertNil(try store.link(rideId: "f")?.startPlaceId)
        XCTAssertEqual(try store.link(rideId: "f")?.endPlaceId, home)

        // "Not a route" takes the route away, the places stay
        try RouteService.dismiss(routeId: try XCTUnwrap(c.routeId), database: db)
        XCTAssertNil(try store.link(rideId: "c")?.routeId)
        XCTAssertEqual(try store.link(rideId: "c")?.startPlaceId, work)
    }

    func test_B24_relinkPass_givesStoredRidesTheirLinks_once_withNoRowLost() throws {
        let db = try open()
        let store = RouteQueries(db)
        // as build 164 left them: a commute route, the way back and a ride home with no place and no route
        try ride(db, "a", SyntheticRoutes.main, at: 0)
        try ride(db, "b", SyntheticRoutes.main, at: 1)
        for (id, path, k) in [("c", back, 1.4), ("f", toHome, 2.0), ("g", back, 2.4)] {
            try RouteFixtures.insertRide(db, id: id, path: path, startAt: base + Int64(k * Double(day)))
        }
        let before = try db.allRowCounts()

        let result = try XCTUnwrap(try RouteRelink.runOnce(database: db))
        XCTAssertEqual(result.rides, 5)
        XCTAssertEqual(result.placedBefore, 2)
        XCTAssertEqual(result.placedAfter, 5)
        XCTAssertEqual(result.routedBefore, 2)
        XCTAssertEqual(result.routedAfter, 4)
        XCTAssertEqual(result.routesAfter, 2)
        let wayBack = try XCTUnwrap(try store.link(rideId: "c")?.routeId)
        XCTAssertEqual(try store.link(rideId: "g")?.routeId, wayBack)
        XCTAssertEqual(try store.rideCount(routeId: wayBack), 2)
        XCTAssertNotNil(try store.link(rideId: "f")?.endPlaceId)
        XCTAssertNil(try store.link(rideId: "f")?.routeId)

        // a9: no table lost a row
        let after = try db.allRowCounts()
        for (table, count) in before { XCTAssertGreaterThanOrEqual(after[table] ?? 0, count, "rows lost in \(table)") }
        let verdict = UpdateCheckRules.verdict(before: before, after: after)
        XCTAssertTrue(verdict.passed, verdict.note)

        // once only, and running it again changes nothing
        XCTAssertNil(try RouteRelink.runOnce(database: db))
        XCTAssertNotNil(try RideQueries(db).setting(key: RouteRelink.settingKey))
        let links = try ["a", "b", "c", "f", "g"].map { try store.link(rideId: $0) }
        let again = try RouteRelink.run(database: db)
        XCTAssertEqual(again.placedAfter, again.placedBefore)
        XCTAssertEqual(again.routedAfter, again.routedBefore)
        XCTAssertEqual(again.routesAfter, again.routesBefore)
        XCTAssertEqual(try ["a", "b", "c", "f", "g"].map { try store.link(rideId: $0) }, links)
        XCTAssertEqual(try db.allRowCounts(), after)
    }

    /// The frozen 1.0 database (every table filled) goes through the pass with no row lost.
    func test_B24_relinkPass_onTheFrozen10Database_keepsEveryRow() throws {
        let source = try XCTUnwrap(Bundle(for: RouteRelinkTests.self).url(forResource: "p5-1.0-frozen", withExtension: "sqlite"))
        let url = folder.appendingPathComponent("corckie.sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        let db = try AppDatabase(url: url, build: "test-b24")
        let before = try db.allRowCounts()
        XCTAssertNotNil(try RouteRelink.runOnce(database: db))
        let after = try db.allRowCounts()
        for (table, count) in before { XCTAssertGreaterThanOrEqual(after[table] ?? 0, count, "rows lost in \(table)") }
    }
}
