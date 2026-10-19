import CorckieCore
import CorckieSim
import Foundation
import GRDB
import XCTest

/// V17: the last parked spot comes from the end point the last finished ride already stored (made-up rides on the synthetic map).
final class ParkedLoaderTests: XCTestCase {
    private var folder: URL!
    private let base: Int64 = 1_790_000_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-parked-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t")
    }

    func test_noRides_noSpot() throws {
        XCTAssertNil(ParkedLoader.latest(database: try open(), simulated: false))
    }

    func test_lastRidesLastGpsSample_isTheSpot() throws {
        let db = try open()
        try RouteFixtures.insertRide(db, id: "old", path: SyntheticRoutes.main, startAt: base, simulated: false)
        try RouteFixtures.insertRide(db, id: "new", path: Array(SyntheticRoutes.main.reversed()), startAt: base + 86_400_000, simulated: false)
        let spot = try XCTUnwrap(ParkedLoader.latest(database: db, simulated: false))
        let samples = try RouteQueries(db).pathSamples(rideId: "new")
        let last = try XCTUnwrap(samples.last)
        XCTAssertEqual(spot.lat, try XCTUnwrap(last.lat), accuracy: 1e-9)
        XCTAssertEqual(spot.lon, try XCTUnwrap(last.lon), accuracy: 1e-9)
        let ride = try XCTUnwrap(try RideQueries(db).ride(id: "new"))
        XCTAssertEqual(spot.endedAtMs, ride.endAt)
        XCTAssertNil(spot.placeName)
    }

    func test_endPlaceNameComesAlong_andSimulatedRidesStayOut() throws {
        let db = try open()
        try RouteFixtures.insertRide(db, id: "real", path: SyntheticRoutes.main, startAt: base, simulated: false)
        try RouteFixtures.insertRide(db, id: "fake", path: SyntheticRoutes.main, startAt: base + 86_400_000, simulated: true)
        let store = RouteQueries(db)
        try store.save(place: PlaceRecord(id: "w", name: "Work", lat: 10, lon: 20, radiusM: nil, canCharge: false, learnedAltM: nil, createdAt: base))
        try store.setPlaces(rideId: "real", startPlaceId: nil, endPlaceId: "w")
        let spot = try XCTUnwrap(ParkedLoader.latest(database: db, simulated: false))
        XCTAssertEqual(spot.placeName, "Work")
        XCTAssertEqual(spot.endedAtMs, try XCTUnwrap(try RideQueries(db).ride(id: "real")?.endAt), "the simulated ride is not the parked spot")
        let sim = try XCTUnwrap(ParkedLoader.latest(database: db, simulated: true))
        XCTAssertEqual(sim.endedAtMs, try XCTUnwrap(try RideQueries(db).ride(id: "fake")?.endAt))
    }

    func test_noGps_fallsBackToTheEndPlace() throws {
        let db = try open()
        try RouteFixtures.insertRide(db, id: "r", path: SyntheticRoutes.main, startAt: base, simulated: false, noGpsFirstSeconds: 100_000)
        XCTAssertNil(ParkedLoader.latest(database: db, simulated: false), "no GPS and no end place: nothing to show")
        let store = RouteQueries(db)
        try store.save(place: PlaceRecord(id: "w", name: nil, lat: 10.5, lon: 20.5, radiusM: nil, canCharge: false, learnedAltM: nil, createdAt: base))
        try store.setPlaces(rideId: "r", startPlaceId: nil, endPlaceId: "w")
        let spot = try XCTUnwrap(ParkedLoader.latest(database: db, simulated: false))
        XCTAssertEqual(spot.lat, 10.5, accuracy: 1e-9)
        XCTAssertEqual(spot.lon, 20.5, accuracy: 1e-9)
    }
}
