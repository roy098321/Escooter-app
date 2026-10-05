import CorckieCore
import Foundation
import GRDB
import XCTest

/// M4-07 / M4-08 on the real schema: Stats totals from stored rides, the empty period, price settings, the Factors page rows.
final class StatsStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-stats-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1")
    }

    func test_totalsAddUpToTheStoredRides() throws {
        let db = try open()
        let r = try InsightSeed.windyWeek(db, rides: 24)
        let m = StatsLoader.load(db, span: .month, mode: .rolling, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
        let from = r.nowMs - 30 * 86_400_000
        let sums = try db.writer.read { d in
            try Row.fetchOne(d, sql: "SELECT COUNT(*) AS n, SUM(distanceM) AS dist, SUM(usedPct) AS used FROM ride WHERE startAt >= ? AND startAt < ?", arguments: [from, r.nowMs + 1])
        }
        let n: Int = sums?["n"] ?? -1
        let dist: Double = sums?["dist"] ?? -1
        let used: Double = sums?["used"] ?? -1
        XCTAssertGreaterThan(n, 10)
        XCTAssertEqual(m.totals.rides, n)
        XCTAssertEqual(m.totals.km, dist / 1000, accuracy: 0.01)
        XCTAssertEqual(m.totals.charges, used / 100, accuracy: 0.0001)
        XCTAssertEqual(m.totals.barsKm.count, 30)
        XCTAssertEqual(m.totals.barsKm.reduce(0, +), dist / 1000, accuracy: 0.01)
    }

    func test_emptyPeriodAndTexts() throws {
        let db = try open()
        let m = StatsLoader.load(db, span: .week, mode: .calendar, nowMs: 1_790_000_000_000, utcOffsetMin: 180)
        XCTAssertTrue(m.totals.isEmpty)
        XCTAssertNil(m.comparisonPct)
        XCTAssertFalse(StatsLoader.tiles(m).isEmpty)
        XCTAssertEqual(StatsLoader.tiles(m).first?.value, "0")
    }

    func test_priceSettingsChangeTheElectricityCost() throws {
        let db = try open()
        let r = try InsightSeed.windyWeek(db, rides: 12)
        let before = StatsLoader.load(db, span: .month, mode: .rolling, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
        try StatsQueries(db).setNumber(StatsQueries.electricityKey, 1.28)
        let after = StatsLoader.load(db, span: .month, mode: .rolling, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
        XCTAssertEqual(before.electricityIlsPerKwh, 0.64, accuracy: 0.0001)
        XCTAssertEqual(after.totals.electricityIls, before.totals.electricityIls * 2, accuracy: 0.0001)
        try StatsQueries(db).setNumber(StatsQueries.fuelUseKey, 14)
        XCTAssertEqual(StatsLoader.load(db, span: .month, mode: .rolling, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin).fuelLPer100km, 14)
    }

    func test_factorsPageFromTheSimulatedWeek() throws {
        let db = try open()
        // 24 windy rides: the wind effect on the route passes its gate
        _ = try InsightSeed.windyWeek(db, rides: 24)
        let rows = FactorsPage.rows(FactorEffects.forRoute(db, routeId: InsightSeed.routeId))
        XCTAssertTrue(rows.contains { $0.title == "Headwind" && $0.hasEffect && ($0.basedOn ?? "").hasPrefix("based on") })
        // 4 rides: progress only
        let few = try AppDatabase(url: folder.appendingPathComponent("few.sqlite"), build: "t1")
        _ = try InsightSeed.windyWeek(few, rides: 4)
        let sparse = FactorsPage.rows(FactorEffects.forRoute(few, routeId: InsightSeed.routeId))
        XCTAssertTrue(sparse.allSatisfy { !$0.hasEffect })
        XCTAssertTrue(sparse.contains { $0.progress == "2 of 3 windy rides" })
    }

    func test_weekCardAndPastWeeks() throws {
        let db = try open()
        let r = try InsightSeed.windyWeek(db, rides: 24)
        // nothing is stored for old weeks, they are made live from the rides
        let past = InsightRunner.pastWeeks(db, nowMs: r.nowMs + 14 * 86_400_000, utcOffsetMin: FactorSeed.utcOffsetMin)
        XCTAssertFalse(past.isEmpty)
        XCTAssertTrue(past.allSatisfy { $0.title.hasPrefix("Week of ") && ($0.lines.first ?? "").hasPrefix("Week of ") })
        XCTAssertEqual(past.map(\.start), past.map(\.start).sorted(by: >))
        // the loader gives this week's and last week's card
        let m = StatsLoader.load(db, span: .week, mode: .calendar, nowMs: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
        XCTAssertTrue((m.lastWeek + m.thisWeek).contains { $0.type == .q22Weekly })
    }

    func test_oneRidingDayHasNoWeekSummary() throws {
        let db = try open()
        let ids = try FactorSeed.commute(db, routeId: "seed-route", n: 1)
        let ride = try InsightQueries(db).ride(ids[0])
        let start = InsightWeek.start(ms: ride?.startAt ?? 0, utcOffsetMin: FactorSeed.utcOffsetMin)
        let found = try InsightRunner.weekCandidates(db, start: start, label: "Week", nowMs: (ride?.startAt ?? 0) + 86_400_000)
        XCTAssertTrue(found.isEmpty)
    }
}
