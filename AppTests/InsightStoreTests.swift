import CorckieCore
import Foundation
import GRDB
import XCTest

/// M4-03: the insight catalogue on the real schema (`insight`, migration v1): the "simulated windy week" (made-up rides in
/// the ocean) gives the progress line below the gate and the wind credit above it; re-runs make no duplicate ids; a late card
/// for a seen summary goes to Recent only; the week card is built.
final class InsightStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-insight-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open(_ name: String = "corckie.sqlite") throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent(name), build: "t1")
    }

    func test_belowTheGate_progressLineOnly() throws {
        let db = try open()
        let r = try InsightSeed.windyWeek(db, rides: 4)
        let ranked = try InsightQueries(db).ranked(forRide: r.lastRideId, nowMs: r.nowMs)
        XCTAssertNil(ranked.top)
        XCTAssertEqual(ranked.progress.map(\.text), ["Headwind on Seed commute: 2 of 3 windy rides"])
        let stored = try InsightQueries(db).forRide(r.lastRideId)
        XCTAssertTrue(stored.allSatisfy { $0.isProgress })
        XCTAssertEqual(stored.first?.storedType, "progress.q15After")
    }

    func test_aboveTheGate_windCredit_andNoDuplicates() throws {
        let db = try open()
        let r = try InsightSeed.windyWeek(db, rides: 24)
        let store = InsightQueries(db)
        let ranked = try store.ranked(forRide: r.lastRideId, nowMs: r.nowMs)
        let all = [ranked.top].compactMap { $0 } + ranked.more
        let credit = try XCTUnwrap(all.first { $0.type == .q15After })
        XCTAssertTrue(credit.text.hasPrefix("Tailwind saved you"), credit.text)
        XCTAssertFalse(ranked.progress.contains { $0.type == .q15After })
        let ids = try store.forRide(r.lastRideId).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let again = try InsightRunner.afterRide(db, rideId: r.lastRideId, nowMs: r.nowMs + 60_000)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(Set(try store.forRide(r.lastRideId).map(\.id)), Set(ids))
        // earlier rides got their cards when their weather arrived (FactorUpdater → weatherArrived)
        XCTAssertGreaterThan(try store.count().rows, ids.count)
        for i in try store.all() { XCTAssertEqual(InsightText.bannedIn(i.text), [], i.text) }
    }

    func test_lateCard_forSeenSummary_goesToRecentOnly() throws {
        let db = try open()
        let r = try InsightSeed.windyWeek(db, rides: 24)
        let store = InsightQueries(db)
        let credit = try XCTUnwrap(try store.forRide(r.lastRideId).first { $0.type == .q15After })
        try store.markShown(rideId: r.lastRideId, at: r.nowMs)
        XCTAssertTrue(try store.summarySeen(rideId: r.lastRideId))
        try db.writer.write { d in try d.execute(sql: "DELETE FROM insight WHERE id = ?", arguments: [credit.id]) }
        try InsightRunner.afterRide(db, rideId: r.lastRideId, nowMs: r.nowMs + 120_000)
        let late = try XCTUnwrap(try store.forRide(r.lastRideId).first { $0.id == credit.id })
        XCTAssertEqual(late.moment, .recentOnly)
        XCTAssertNotEqual(try store.top(forRide: r.lastRideId, nowMs: r.nowMs + 120_000)?.id, credit.id)
        XCTAssertEqual(try store.recent().first?.id, credit.id)
        // dismissed rows stay gone
        try store.dismiss(id: credit.id, at: r.nowMs + 130_000)
        try InsightRunner.afterRide(db, rideId: r.lastRideId, nowMs: r.nowMs + 140_000)
        XCTAssertNotNil(try store.forRide(r.lastRideId).first { $0.id == credit.id }?.dismissedAt)
        XCTAssertFalse(try store.recent().contains { $0.id == credit.id })
    }

    func test_weekCard_andRecentOrder() throws {
        let db = try open()
        let r = try InsightSeed.windyWeek(db, rides: 24)
        let store = InsightQueries(db)
        let ws = InsightWeek.start(ms: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
        let cards = try store.weekCard(weekStart: ws) + store.weekCard(weekStart: ws - 7 * OutsideTime.dayMs)
        XCTAssertTrue(cards.contains { $0.type == .q22Weekly && ($0.text.hasPrefix("Last week:") || $0.text.hasPrefix("This week so far:")) },
                      cards.map(\.text).joined(separator: " | "))
        let recent = try store.recent()
        XCTAssertLessThanOrEqual(recent.count, 10)
        XCTAssertEqual(recent.map(\.createdAt), recent.map(\.createdAt).sorted(by: >))
        XCTAssertFalse(recent.contains { $0.isProgress })
    }

    func test_rideStart_nothingToSay_noCrash() throws {
        let db = try open()
        let pick = InsightRunner.atRideStart(db, routeId: nil, battery: BatteryNow(pct: 50), lat: nil, lon: nil, nowMs: FactorSamples.t0)
        XCTAssertEqual(pick.shown, [])
        XCTAssertEqual(pick.toSummary, [])
        XCTAssertEqual(try InsightQueries(db).count().rows, 0)
    }
}
