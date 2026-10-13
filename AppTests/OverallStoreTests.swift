import CorckieCore
import Foundation
import GRDB
import XCTest

/// F-01: price history (migration v4), the Overall numbers from stored rides, and the price lock on the real schema.
final class OverallStoreTests: XCTestCase {
    private var folder: URL!
    /// 2026-10-05 12:00 UTC+3 = 09:00 UTC
    private let oct5: Int64 = 1_791_190_800_000
    private let day: Int64 = 86_400_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-overall-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "ov")
    }

    private func addRide(_ q: RideQueries, _ id: String, at: Int64, km: Double, odoStart: Double, used: Double) throws {
        var r = RideRecord(id: id, startAt: at)
        r.endAt = at + 1_800_000
        r.status = "ended"
        r.utcOffsetMin = 180
        r.distanceM = km * 1000
        r.odoStartKm = odoStart
        r.odoEndKm = odoStart + km
        r.usedPct = used
        try q.save(r)
    }

    func test_defaults_septemberAndOctober_neverReplaceAnEditedRow() throws {
        let db = try open()
        let q = PriceHistoryQueries(db)
        q.ensureDefaults()
        var rows = try q.rows(kind: PriceHistoryQueries.fuel)
        XCTAssertEqual(rows.map(\.validFrom), ["2026-09-01", "2026-10-01"])
        XCTAssertEqual(rows.map(\.value), [8.25, 8.27])
        XCTAssertEqual(rows[0].source, PriceHistoryQueries.septemberSource)
        // the owner corrects September; the next launch keeps the correction
        try q.set(PriceRow(kind: "fuel", validFrom: "2026-09-01", value: 8.30, source: "manual", unverified: false))
        q.ensureDefaults()
        rows = try q.rows(kind: PriceHistoryQueries.fuel)
        XCTAssertEqual(rows.first?.value, 8.30)
    }

    func test_electricity_firstChangeKeepsTheOldRateForThePast() throws {
        let db = try open()
        let q = PriceHistoryQueries(db)
        XCTAssertEqual(OverallLoader.electricityHistory(db).value(on: "2026-10-01"), 0.64, "no rows: the default has always applied")
        try q.setElectricity(0.70, from: "2026-11-01", currentDefault: 0.64)
        let h = OverallLoader.electricityHistory(db)
        XCTAssertEqual(h.value(on: "2026-10-31"), 0.64)
        XCTAssertEqual(h.value(on: "2026-11-01"), 0.70)
    }

    func test_overall_fromStoredRides_andThePriceLock() throws {
        let db = try open()
        PriceHistoryQueries(db).ensureDefaults()
        try SettingsValue.setForTests(db, OverallSettings.purchaseDayKey, "2026-09-02")
        let rides = RideQueries(db)
        try addRide(rides, "first", at: oct5, km: 19, odoStart: 692.1, used: 48)
        try addRide(rides, "second", at: oct5 + 3 * day, km: 11, odoStart: 711.1, used: 22)

        let now = oct5 + 8 * day
        let before = OverallLoader.load(db, nowMs: now, utcOffsetMin: 180)
        XCTAssertEqual(before.totalKm, 722.1, accuracy: 1e-6)
        XCTAssertEqual(before.kmBefore, 692.1, accuracy: 1e-6)
        XCTAssertEqual(before.kmWithApp, 30, accuracy: 1e-6)
        XCTAssertTrue(before.hasFuelPrice)
        XCTAssertEqual(before.months.map(\.month), ["2026-09", "2026-10"])

        // the price drops from today on: nothing in the past moves
        try PriceHistoryQueries(db).set(PriceRow(kind: "fuel", validFrom: "2026-10-14", value: 5.00, source: "manual", unverified: false))
        let after = OverallLoader.load(db, nowMs: now, utcOffsetMin: 180)
        XCTAssertEqual(after.fuelSavedIls, before.fuelSavedIls, accuracy: 1e-9)
        XCTAssertEqual(after.months, before.months)

        // a later ride at the lower price still adds money: the total never goes down
        try addRide(rides, "third", at: oct5 + 10 * day, km: 8, odoStart: 722.1, used: 17)
        let later = OverallLoader.load(db, nowMs: now + 5 * day, utcOffsetMin: 180)
        XCTAssertGreaterThan(later.fuelSavedIls, after.fuelSavedIls)
        XCTAssertGreaterThan(later.netSavedIls, after.netSavedIls)
    }

    func test_statsPeriodTotals_followThePriceHistory_perRideDay() throws {
        let db = try open()
        PriceHistoryQueries(db).ensureDefaults()
        let rides = RideQueries(db)
        try addRide(rides, "a", at: oct5, km: 10, odoStart: 692.1, used: 20)
        try PriceHistoryQueries(db).setElectricity(2.00, from: "2026-10-20", currentDefault: 0.64)
        let prices = StatsLoader.prices(db)
        let p = StatsCalc.period(span: .month, mode: .calendar, nowMs: oct5, utcOffsetMin: 180)
        let all = try StatsQueries(db).rides(from: p.startMs, to: p.endMs)
        let t = StatsCalc.totals(all, period: p, prices: prices, utcOffsetMin: 180)
        // the ride was on 5 Oct, before the dearer rate: electricity at 0.64
        XCTAssertEqual(t.electricityIls, 0.20 * prices.packWh / 1000 * 0.64, accuracy: 1e-9)
        XCTAssertNotNil(t.fuelSavedIls)
    }
}

extension SettingsValue {
    static func setForTests(_ db: AppDatabase, _ key: String, _ value: String) throws {
        try RideQueries(db).setSetting(key: key, json: value)
    }
}
