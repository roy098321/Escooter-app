import CorckieCore
import GRDB
import XCTest

/// M6-01 (Q23): choice points end to end on the real schema: made-up rides (`ChoiceSeed`) → `FastestService.rebuild` → the three
/// tables → the answer, the route card section, Follow, Q3, and a rebuild that replaces (never doubles) the rows.
final class ChoiceStoreTests: XCTestCase {
    private var db: AppDatabase!
    private let now = ChoiceSamples.t0 + 20 * ChoiceSamples.day

    override func setUpWithError() throws {
        db = try AppDatabase.openTemporary(build: "test")
    }

    override func tearDownWithError() throws {
        db.discardTemporary()
    }

    func testTablesAreFilledAndReplaced() throws {
        try ChoiceSeed.route(db)
        var c = try ChoiceQueries(db).counts(routeId: ChoiceSamples.routeId)
        XCTAssertEqual(c.points, 2)
        XCTAssertEqual(c.options, 4)
        XCTAssertEqual(c.rideOptions, 18)
        try FastestService.rebuild(db, routeId: ChoiceSamples.routeId)
        c = try ChoiceQueries(db).counts(routeId: ChoiceSamples.routeId)
        XCTAssertEqual(c.rideOptions, 18, "a rebuild replaces the rows")
        let ref = Geo.decode(try XCTUnwrap(RouteQueries(db).variants(routeId: ChoiceSamples.routeId).first?.polyline))
        let set = try ChoiceQueries(db).set(routeId: ChoiceSamples.routeId, reference: ref)
        XCTAssertEqual(set.points.count, 2)
        XCTAssertTrue(set.points[0].options[0].isReference)
        XCTAssertEqual(set.points[0].rejoinOnRefM, 1_380, accuracy: 60)
        XCTAssertNotNil(set.costs.first?.energyWh, "energy from the samples' power")
    }

    func testAnswerCardAndFollow() throws {
        try ChoiceSeed.route(db)
        let answer = try XCTUnwrap(FastestService.answer(db, routeId: ChoiceSamples.routeId, nowMs: now, todayLevels: []))
        guard case .combination(let c) = answer.state else { return XCTFail("\(answer.state)") }
        XCTAssertEqual(c.ways.filter { !$0.isReference }.count, 2)
        XCTAssertGreaterThanOrEqual(c.savingS, 66)
        let card = try XCTUnwrap(FastestCard.make(answer))
        XCTAssertTrue(card.canFollow)
        XCTAssertTrue(card.detail.hasSuffix("never ridden as a whole"), card.detail)
        let follow = try XCTUnwrap(RouteFollowLoader.follower(routeId: ChoiceSamples.routeId, database: db, nowMs: now, combination: true))
        XCTAssertEqual(follow.todayS, c.timeS, accuracy: 0.5)
        XCTAssertEqual(follow.path.count, c.path.count)
        let usual = try XCTUnwrap(RouteFollowLoader.follower(routeId: ChoiceSamples.routeId, database: db, nowMs: now))
        XCTAssertNotEqual(usual.path.count, follow.path.count, "without combination: the reference path")
    }

    func testRideCloseHookFillsTheRouteAndQ3() throws {
        let ids = try ChoiceSeed.route(db, rebuild: false)
        XCTAssertEqual(try ChoiceQueries(db).counts(routeId: ChoiceSamples.routeId).points, 0)
        let report = try XCTUnwrap(FastestService.update(db, rideId: ids.last!))
        XCTAssertEqual(report.points, 2)
        try InsightRunner.afterRide(db, rideId: ids[5], nowMs: now)       // the third park ride
        let texts = try db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM insight WHERE type IN ('q3After', 'q3Verdict') AND rideId = ?", arguments: [ids[5]])
        }
        XCTAssertTrue(texts.contains { $0.hasPrefix("Verdict: ") }, texts.joined(separator: " | "))
        // a usual-way ride never gets a Q3 card about the usual way
        try InsightRunner.afterRide(db, rideId: ids[0], nowMs: now)
        let usual = try db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight WHERE type LIKE '%q3%' AND rideId = ?", arguments: [ids[0]]) ?? 0
        }
        XCTAssertEqual(usual, 0)
    }

    func testRideOffAnyRouteDoesNothing() throws {
        try RideToolsSeed.ride(db, id: "lonely", startAt: ChoiceSamples.t0)
        XCTAssertNil(try FastestService.update(db, rideId: "lonely"))
    }
}
