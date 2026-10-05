import CorckieCore
import Foundation
import GRDB
import XCTest

/// M3-02: the charge log on the real schema (migration v1, no schema change): charges found from rested % jumps between
/// rides, rewritten with the rides, and the sag rule only using the next start when no charge is in between.
final class ChargeStoreTests: XCTestCase {
    private var folder: URL!
    private let hour: Int64 = 3_600_000
    private let t0: Int64 = 1_790_000_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-charge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1")
    }

    @discardableResult
    private func add(_ q: RideQueries, _ id: String, hours: Int64, wh: Double = 336, from: Double?, to: Double?, sim: Bool = false,
                     reason: String? = nil, lastLive: Int? = nil) throws -> RideRecord {
        var r = RideRecord(id: id, startAt: t0 + hours * hour)
        r.endAt = r.startAt + 1_800_000
        r.status = "ended"
        r.isSimulated = sim
        r.energyWhRaw = wh
        r.startRestPct = from
        r.endRestPct = to
        r.endReason = reason
        if let from, let to { r.usedPct = from - to; r.usedPctMethod = "rested" }
        r.distanceM = 15_000
        try q.save(r)
        if let lastLive {
            var s = RideSampleRecord(rideId: id, t: 1_000_000)
            s.batteryPct = lastLive
            try q.insert(samples: [s])
        }
        return r
    }

    func test_chargeRowWritten_fromARestedJump_andRewrittenWithTheRides() throws {
        let db = try open()
        let q = RideQueries(db)
        try add(q, "a", hours: 0, from: 85, to: 40)
        try add(q, "b", hours: 20, from: 86, to: 60)
        try add(q, "sim", hours: 21, from: 20, to: 10, sim: true)
        let out = try CalibrationUpdater.update(db, nowMs: t0)
        XCTAssertEqual(out.charges.count, 1)
        let rows = try ChargeQueries(db).all()
        XCTAssertEqual(rows.count, 1)
        let c = try XCTUnwrap(rows.first)
        XCTAssertEqual(c.afterRideId, "a")
        XCTAssertEqual(c.beforeRideId, "b")
        XCTAssertEqual(c.fromPct, 40)
        XCTAssertEqual(c.toPct, 86)
        XCTAssertEqual(c.chargedPct, 46)
        XCTAssertEqual(c.windowStartAt, t0 + 1_800_000)
        XCTAssertEqual(c.windowEndAt, t0 + 20 * hour)
        XCTAssertFalse(c.inferredWhileAway)
        // running again changes nothing
        XCTAssertFalse(try ChargeQueries(db).replaceAll(rows))
        _ = try CalibrationUpdater.update(db, nowMs: t0)
        XCTAssertEqual(try ChargeQueries(db).all(), rows)
        // the ride is removed: the charge row goes with it
        try db.writer.write { try $0.execute(sql: "DELETE FROM ride WHERE id = 'b'") }
        _ = try CalibrationUpdater.update(db, nowMs: t0)
        XCTAssertTrue(try ChargeQueries(db).all().isEmpty)
    }

    func test_shutdownFlag_andSimulatedChargeIsNotStored() throws {
        let db = try open()
        let q = RideQueries(db)
        try add(q, "a", hours: 0, from: 85, to: nil, reason: "scooterOff", lastLive: 30)
        try add(q, "b", hours: 20, from: 100, to: 90)
        try add(q, "s1", hours: 30, from: 40, to: 20, sim: true)
        try add(q, "s2", hours: 40, from: 90, to: 70, sim: true)
        let out = try CalibrationUpdater.update(db, nowMs: t0)
        XCTAssertEqual(out.charges.count, 2)
        let rows = try ChargeQueries(db).all()
        XCTAssertEqual(rows.map(\.beforeRideId), ["b"])
        XCTAssertTrue(rows[0].startedByShutdownFlag)
    }

    func test_sagRule_nextStartIsUsedOnlyWhenNoChargeIsInBetween() throws {
        // a ride switched off before resting (live 50%): next start rested 56 = sag recovery, 30 h later is still fine
        let db = try open()
        let q = RideQueries(db)
        try add(q, "a", hours: 0, wh: 8.4 * 40, from: 96, to: nil, lastLive: 50)
        try add(q, "b", hours: 30, from: 56, to: nil)
        let sag = try CalibrationUpdater.update(db, nowMs: t0)
        XCTAssertTrue(sag.charges.isEmpty)
        XCTAssertEqual(sag.verdicts["a"], .used(whPerPct: 8.4, dropPct: 40, endFromNextStart: true))

        // the next start is 85: a charge in between, so the end is unknown (not "sag") and nothing is calibrated from it
        let db2 = try AppDatabase(url: folder.appendingPathComponent("other.sqlite"), build: "t1")
        let q2 = RideQueries(db2)
        try add(q2, "a", hours: 0, wh: 8.4 * 40, from: 96, to: nil, lastLive: 50)
        try add(q2, "b", hours: 30, from: 85, to: nil)
        let charged = try CalibrationUpdater.update(db2, nowMs: t0)
        XCTAssertEqual(charged.charges.count, 1)
        XCTAssertEqual(charged.verdicts["a"], .rejected(.noRestedEnd))
        XCTAssertEqual(charged.calibration.ridesUsed, 0)
    }

    func test_batteryOverview_rangeChargeTimeAndTheTileThatHidesAfterACharge() throws {
        let db = try open()
        let q = RideQueries(db)
        try add(q, "a", hours: 0, from: 90, to: 50)
        try add(q, "b", hours: 24, from: 90, to: 50)
        // the rides' used % is 40 over 15 km = 2.667 %/km; reserve 5% (nothing ran out)
        let on = BatteryOverview.load(db, currentPct: 50, connected: true)
        XCTAssertEqual(on.range?.pctPerKm ?? 0, 40.0 / 15, accuracy: 1e-9)
        XCTAssertEqual(on.range?.rangeKm ?? 0, 45 / (40.0 / 15), accuracy: 1e-9)
        XCTAssertEqual(on.chargeHours ?? 0, 3.8, accuracy: 1e-9)
        XCTAssertNil(on.sinceLastRide)
        let off = BatteryOverview.load(db, currentPct: 50, connected: false)
        XCTAssertNil(off.chargeHours)
        XCTAssertEqual(off.sinceLastRide?.endPct, 50)
        // a ran-out setting is the reserve
        try q.setSetting(key: "t80.batteryRanOut", json: "{\"pct\":3,\"rideId\":\"a\"}")
        XCTAssertEqual(BatteryOverview.load(db, currentPct: 50, connected: false).reservePct, 3)
        // a charge after the last ride hides the tile (found at the next ride)
        _ = try CalibrationUpdater.update(db, nowMs: t0)
        try add(q, "c", hours: 48, from: 95, to: 80)
        _ = try CalibrationUpdater.update(db, nowMs: t0)
        let later = BatteryOverview.load(db, currentPct: 80, connected: false)
        XCTAssertEqual(later.charges.count, 1)
        XCTAssertEqual(later.charges.first?.chargedPct, 45)
        XCTAssertGreaterThan(later.cycles, 0.9)
        if case .gathering = later.health {} else { XCTFail("health is gathering with 3 rides") }
    }
}
