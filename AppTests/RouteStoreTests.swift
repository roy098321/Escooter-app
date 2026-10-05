import CorckieCore
import CorckieSim
import Foundation
import GRDB
import XCTest

/// M2-01 / M2-02: places, routes and variants on the real schema (no schema change: migration v1 already has them). Made-up
/// rides on the synthetic map are written to a temporary database and run through the same `RouteProcessor` the Recorder
/// calls at every ride close.
final class RouteStoreTests: XCTestCase {
    private var folder: URL!
    private let day: Int64 = 86_400_000
    private let base: Int64 = 1_790_000_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-route-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t")
    }

    @discardableResult
    private func ride(_ db: AppDatabase, _ id: String, _ path: [SyntheticRoutes.XY], day k: Int64, noGps: Int = 0) throws -> RouteProcessResult {
        try RouteFixtures.insertRide(db, id: id, path: path, startAt: base + k * day, noGpsFirstSeconds: noGps)
        return try XCTUnwrap(try RouteProcessor.process(rideId: id, database: db))
    }

    func test_twoTrips_suggest_save_thirdIsMatched() throws {
        let db = try open()
        let store = RouteQueries(db)
        let first = try ride(db, "a", SyntheticRoutes.main, day: 0)
        XCTAssertEqual(first.outcome, .pending)
        XCTAssertNil(first.routeId)
        let second = try ride(db, "b", SyntheticRoutes.main, day: 1)
        XCTAssertEqual(second.outcome, .suggested)
        XCTAssertEqual(second.ridesOnRoute, 2)
        let routeId = try XCTUnwrap(second.routeId)
        let counts = try store.counts()
        XCTAssertEqual(counts.places, 2)
        XCTAssertEqual(counts.routes, 1)
        XCTAssertEqual(counts.variants, 1)
        XCTAssertEqual(try store.route(id: routeId)?.state, "suggested")
        XCTAssertEqual(try store.link(rideId: "a")?.routeId, routeId)
        XCTAssertEqual(try store.link(rideId: "b")?.routeId, routeId)
        XCTAssertNotNil(try store.link(rideId: "b")?.startPlaceId)
        XCTAssertEqual(try RideQueries(db).ride(id: "b")?.kind, "ride")
        let offer = try XCTUnwrap(RouteService.offer(rideId: "b", database: db))
        XCTAssertEqual(offer.headline, "Save as route?")

        try RouteService.save(routeId: routeId, database: db)
        XCTAssertEqual(try store.route(id: routeId)?.state, "saved")
        XCTAssertTrue(try XCTUnwrap(RouteService.offer(rideId: "b", database: db)).saved)

        let third = try ride(db, "c", SyntheticRoutes.main, day: 2)
        XCTAssertEqual(third.outcome, .matched)
        XCTAssertEqual(third.ridesOnRoute, 3)
        XCTAssertEqual(try store.route(id: routeId)?.usualDistanceM ?? 0, 3_700, accuracy: 1)
        XCTAssertEqual(try store.counts().routes, 1)
        XCTAssertEqual(try store.routeRides(routeId: routeId).map { $0.id }, ["c", "b", "a"], "newest first")
        // check q2: the processing time is recorded
        XCTAssertNotNil(try RideQueries(db).setting(key: "q2.routeMs"))
    }

    func test_loop_noGps_dismissed() throws {
        let db = try open()
        let store = RouteQueries(db)
        XCTAssertEqual(try ride(db, "l1", SyntheticRoutes.loop, day: 0).outcome, .loop)
        XCTAssertEqual(try ride(db, "l2", SyntheticRoutes.loop, day: 1).outcome, .loop)
        XCTAssertEqual(try ride(db, "n1", SyntheticRoutes.main, day: 2, noGps: 200).outcome, .noGps)
        XCTAssertEqual(try store.counts().routes, 0)
        XCTAssertNil(try store.link(rideId: "l1")?.routeId)

        // a trip somewhere else, suggested, then "Not a route"
        let far = SyntheticRoutes.offset(SyntheticRoutes.main, by: (x: 8_000, y: 0))
        try ride(db, "x1", far, day: 3)
        let x2 = try ride(db, "x2", far, day: 4)
        let routeId = try XCTUnwrap(x2.routeId)
        try RouteService.dismiss(routeId: routeId, database: db)
        XCTAssertEqual(try store.route(id: routeId)?.state, "dismissed")
        XCTAssertNil(try store.link(rideId: "x1")?.routeId, "its rides lose the link")
        XCTAssertNil(RouteService.offer(rideId: "x2", database: db))
        let x3 = try ride(db, "x3", far, day: 5)
        XCTAssertEqual(x3.outcome, .dismissedRoute)
        XCTAssertEqual(try store.counts().routes, 1, "no second suggestion for the same trip")
    }

    func test_detour_isASecondVariant_andTheOwnersNameSurvives() throws {
        let db = try open()
        let store = RouteQueries(db)
        try ride(db, "a", SyntheticRoutes.main, day: 0)
        let b = try ride(db, "b", SyntheticRoutes.main, day: 1)
        let routeId = try XCTUnwrap(b.routeId)
        try RouteService.save(routeId: routeId, database: db)
        let c = try ride(db, "c", SyntheticRoutes.detour, day: 2)
        XCTAssertEqual(c.outcome, .matched)
        XCTAssertEqual(c.newVariantIds.count, 1)
        let d = try ride(db, "d", SyntheticRoutes.detour, day: 3)
        XCTAssertTrue(d.newVariantIds.isEmpty)
        let variants = try store.variants(routeId: routeId)
        XCTAssertEqual(variants.map { $0.name }, ["Variant 1", "Variant 2"])
        XCTAssertEqual(variants.filter { $0.isReference }.count, 1)
        XCTAssertEqual(c.variantId, d.variantId)
        XCTAssertNotEqual(try store.link(rideId: "a")?.variantId, c.variantId)
        // the path is stored encoded and reads back
        let path = Geo.decode(try XCTUnwrap(variants[1].polyline))
        XCTAssertGreaterThan(path.count, 300)
        // a street name from the phone replaces a fallback name, an owner's name is never replaced
        try store.rename(variantId: variants[1].id, name: "via Herzl", byHand: false)
        try store.rename(variantId: variants[0].id, name: "Usual way", byHand: true)
        let names = try store.variants(routeId: routeId)
        XCTAssertEqual(names.map { $0.name }, ["Usual way", "via Herzl"])
        XCTAssertEqual(names.map { $0.nameByHand }, [true, false])
        try ride(db, "e", SyntheticRoutes.main, day: 4)
        XCTAssertEqual(try store.variants(routeId: routeId).first?.name, "Usual way")
    }

    func test_rename_remove_andRidesStay() throws {
        let db = try open()
        let store = RouteQueries(db)
        try ride(db, "a", SyntheticRoutes.main, day: 0)
        let b = try ride(db, "b", SyntheticRoutes.main, day: 1)
        let routeId = try XCTUnwrap(b.routeId)
        XCTAssertEqual(RouteService.title(routeId: routeId, database: db), "Route 1", "places have no name yet")
        let fromId = try XCTUnwrap(try store.route(id: routeId)?.fromPlaceId)
        let toId = try XCTUnwrap(try store.route(id: routeId)?.toPlaceId)
        try store.rename(placeId: fromId, name: "Home")
        try store.rename(placeId: toId, name: "Work")
        XCTAssertEqual(RouteService.title(routeId: routeId, database: db), "Home \u{2192} Work")
        try RouteService.rename(routeId: routeId, name: "Commute", database: db)
        XCTAssertEqual(RouteService.title(routeId: routeId, database: db), "Commute")
        try RouteService.rename(routeId: routeId, name: "  ", database: db)
        XCTAssertEqual(RouteService.title(routeId: routeId, database: db), "Home \u{2192} Work")
        try store.deleteRoute(id: routeId)
        XCTAssertEqual(try store.counts().routes, 0)
        XCTAssertEqual(try store.counts().variants, 0)
        XCTAssertNotNil(try RideQueries(db).ride(id: "a"), "the rides stay")
        XCTAssertNil(try store.link(rideId: "a")?.routeId)
    }

    func test_routeRides_feedTheRouteStatistics() throws {
        let db = try open()
        let store = RouteQueries(db)
        try ride(db, "a", SyntheticRoutes.main, day: 0)
        let b = try ride(db, "b", SyntheticRoutes.main, day: 1)
        let rows = try store.routeRides(routeId: try XCTUnwrap(b.routeId))
        XCTAssertEqual(rows.count, 2)
        let stats = rows.map {
            RouteRideStats(rideId: $0.id, startAt: $0.startAt, utcOffsetMin: $0.utcOffsetMin ?? 0, variantId: $0.variantId, totalS: $0.totalS,
                           distanceM: $0.distanceM, avgMovingMps: $0.avgMovingMps, usedPct: $0.usedPct, elevGainM: $0.elevGainM,
                           elevLossM: $0.elevLossM, excluded: $0.excludedFromUsual, windLevel: $0.windLevel, wet: $0.wet)
        }
        XCTAssertEqual(stats[0].totalS ?? 0, 535, accuracy: 1)
        XCTAssertEqual(stats[0].usedPct, 6)
    }

    func test_polylineRoundTrip_andTheDatabaseOpens() throws {
        let db = try open()
        XCTAssertFalse(db.isReadOnly)
        // the encoded polyline round trip of a stored variant is exact to 1e-5 degrees
        let pts = [GeoPoint(lat: 10.12345, lon: -30.54321), GeoPoint(lat: 10.12445, lon: -30.54221)]
        let back = Geo.decode(Geo.encode(pts))
        XCTAssertEqual(back[1].lat, 10.12445, accuracy: 1e-5)
        XCTAssertEqual(back[1].lon, -30.54221, accuracy: 1e-5)
    }
}
