import GRDB
import XCTest

/// M5-02 / M5-05: merge, undo, trim and reset on the real schema, and the lossless ride bundle.
final class RideToolsStoreTests: XCTestCase {
    private var db: AppDatabase!
    private var folder: URL!
    private let t0: Int64 = 1_790_000_000_000

    override func setUpWithError() throws {
        db = try AppDatabase.openTemporary(build: "test")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-undo-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        db.discardTemporary()
        try? FileManager.default.removeItem(at: folder)
    }

    private func seedPair() throws {
        try RideToolsSeed.ride(db, id: "A", startAt: t0)
        try RideToolsSeed.ride(db, id: "B", startAt: t0 + 1_095_000, odoStartKm: 102.475, lat0: 10.0198)
    }

    func testSeedRideHasNumbers() throws {
        try seedPair()
        let a = try XCTUnwrap(RideQueries(db).ride(id: "A"))
        XCTAssertEqual(a.distanceM ?? 0, 2_475, accuracy: 1)
        XCTAssertEqual(a.kind, "ride")
    }

    func testMergeAddsUpAndUndoBringsBothBack() throws {
        try seedPair()
        let q = RideQueries(db)
        let before = try XCTUnwrap(q.ride(id: "A")?.distanceM)
        let offer = RideToolsService.mergeOffer(db, rideId: "B")
        XCTAssertEqual(offer?.previousId, "A")
        XCTAssertEqual(offer?.offer.gapS, 600)

        try RideToolsService.merge(db, firstId: "A", secondId: "B", nowMs: t0 + 2_000_000, undoFolder: folder)
        let merged = try XCTUnwrap(q.ride(id: "A"))
        XCTAssertNil(try q.ride(id: "B"))
        XCTAssertEqual(try q.sampleCount(rideId: "A"), 200)
        XCTAssertEqual(merged.distanceM ?? 0, 4_950, accuracy: 2)
        XCTAssertEqual(merged.stops, 1)
        XCTAssertLessThan(merged.gapScooterS ?? 99, 1)
        XCTAssertEqual(merged.totalS ?? 0, 1_590, accuracy: 1)
        XCTAssertEqual(merged.movingS ?? 0, 990, accuracy: 1)
        XCTAssertEqual(merged.endAt, t0 + 1_095_000 + 495_000)
        XCTAssertTrue(try q.stops(rideId: "A").contains { $0.id.hasPrefix("bridge-") })
        XCTAssertTrue(RideToolsService.canUndoMerge(db))

        try RideToolsService.undoMerge(db, undoFolder: folder)
        XCTAssertFalse(RideToolsService.canUndoMerge(db))
        XCTAssertEqual(try q.sampleCount(rideId: "A"), 100)
        XCTAssertEqual(try q.sampleCount(rideId: "B"), 100)
        XCTAssertEqual(try XCTUnwrap(q.ride(id: "A")?.distanceM), before, accuracy: 0.5)
        XCTAssertEqual(try q.ride(id: "B")?.startAt, t0 + 1_095_000)
        XCTAssertTrue(try q.stops(rideId: "A").isEmpty)
    }

    func testTrimDoesNotDeleteAndResetBringsBackTheOriginal() throws {
        try RideToolsSeed.ride(db, id: "A", startAt: t0)
        let q = RideQueries(db)
        let original = try XCTUnwrap(q.ride(id: "A"))
        try RideToolsService.trim(db, rideId: "A", startS: 100, endS: 300)
        let cut = try XCTUnwrap(q.ride(id: "A"))
        XCTAssertEqual(cut.distanceM ?? 0, 1_000, accuracy: 2)
        XCTAssertEqual(cut.totalS ?? 0, 200, accuracy: 1)
        XCTAssertEqual(cut.trimStartAt, t0 + 100_000)
        XCTAssertEqual(cut.trimEndAt, t0 + 300_000)
        XCTAssertEqual(try q.sampleCount(rideId: "A"), 100)

        // trimming again keeps the very first numbers as the ones to come back to
        try RideToolsService.trim(db, rideId: "A", startS: 50, endS: 400)
        try RideToolsService.resetTrim(db, rideId: "A")
        let back = try XCTUnwrap(q.ride(id: "A"))
        XCTAssertNil(back.trimStartAt)
        XCTAssertEqual(back.distanceM ?? 0, original.distanceM ?? 0, accuracy: 0.0001)
        XCTAssertEqual(back.totalS ?? 0, original.totalS ?? 0, accuracy: 0.0001)
        XCTAssertNil(try q.setting(key: RideToolsService.originalKey("A")))
    }

    func testTrimTooShortIsRefused() throws {
        try RideToolsSeed.ride(db, id: "A", startAt: t0, n: 10)
        XCTAssertThrowsError(try RideToolsService.trim(db, rideId: "A", startS: 0, endS: 40))
    }

    func testTwoRidesFarApartAreNotOffered() throws {
        try RideToolsSeed.ride(db, id: "A", startAt: t0)
        try RideToolsSeed.ride(db, id: "B", startAt: t0 + 1_095_000, odoStartKm: 102.475, lat0: 10.5)
        XCTAssertNil(RideToolsService.mergeOffer(db, rideId: "B"))
    }

    func testBundleRoundTripIsLosslessAndNeverDuplicates() throws {
        try RideToolsSeed.ride(db, id: "A", startAt: t0)
        let q = RideQueries(db)
        try db.writer.write { d in
            try d.execute(sql: "UPDATE ride SET loadKg = 7.5, routeId = 'r1', headwindKmh = 12.25, promptAnswer = 'likelyLoaded' WHERE id = 'A'")
        }
        let bundle = try XCTUnwrap(db.writer.read { try RideBundle.read($0, rideId: "A") })
        XCTAssertEqual(bundle.sampleCount, 100)
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(RideBundle.self, from: data)
        XCTAssertEqual(decoded, bundle)

        let other = try AppDatabase.openTemporary(build: "test")
        defer { other.discardTemporary() }
        let added = try other.writer.write { try decoded.insert($0) }
        XCTAssertTrue(added)
        let again = try other.writer.write { try decoded.insert($0) }
        XCTAssertFalse(again)
        XCTAssertEqual(try RideQueries(other).sampleCount(rideId: "A"), 100)
        let kg = try other.writer.read { try Double.fetchOne($0, sql: "SELECT loadKg FROM ride WHERE id = 'A'") }
        let route = try other.writer.read { try String.fetchOne($0, sql: "SELECT routeId FROM ride WHERE id = 'A'") }
        let wind = try other.writer.read { try Double.fetchOne($0, sql: "SELECT headwindKmh FROM ride WHERE id = 'A'") }
        let answer = try other.writer.read { try String.fetchOne($0, sql: "SELECT promptAnswer FROM ride WHERE id = 'A'") }
        XCTAssertEqual(kg, 7.5)
        XCTAssertEqual(route, "r1")
        XCTAssertEqual(wind, 12.25)
        XCTAssertEqual(answer, "likelyLoaded")
        let distance = try other.writer.read { try Double.fetchOne($0, sql: "SELECT distanceM FROM ride WHERE id = 'A'") }
        let expected = try XCTUnwrap(q.ride(id: "A")?.distanceM)
        XCTAssertEqual(distance ?? 0, expected, accuracy: 0.001)
    }
}
