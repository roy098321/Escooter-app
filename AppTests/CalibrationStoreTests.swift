import CorckieCore
import Foundation
import GRDB
import XCTest

/// M3-01: the `calibration` row and the rides' used % re-run, on the real schema (migration v1, no schema change).
final class CalibrationStoreTests: XCTestCase {
    private var folder: URL!
    private let day: Int64 = 86_400_000
    private let t0: Int64 = 1_790_000_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-cal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1")
    }

    private func add(_ q: RideQueries, _ id: String, _ i: Int, wh: Double, from: Double, to: Double?, sim: Bool = false,
                     status: String = "ended", lastLive: Int? = nil) throws {
        var r = RideRecord(id: id, startAt: t0 + Int64(i) * day)
        r.endAt = r.startAt + 1_800_000
        r.status = status
        r.isSimulated = sim
        r.energyWhRaw = wh
        r.startRestPct = from
        r.endRestPct = to
        if let to {
            r.usedPct = from - to
            r.usedPctMethod = "rested"
        }
        r.distanceM = 15_000
        try q.save(r)
        if let lastLive {
            var s = RideSampleRecord(rideId: id, t: 1_000_000)
            s.batteryPct = lastLive
            try q.insert(samples: [s])
        }
    }

    func test_noRides_isThePrior() throws {
        let db = try open()
        XCTAssertNil(try CalibrationQueries(db).current())
        XCTAssertEqual(CalibrationUpdater.current(db), BatteryCalibration.prior())
        XCTAssertEqual(CalibrationUpdater.current(nil), BatteryCalibration.prior())
    }

    func test_threeRealRides_learningRowSaved_ridesKeepRested() throws {
        let db = try open()
        let q = RideQueries(db)
        try add(q, "29sep", 0, wh: 322, from: 64, to: 23)
        try add(q, "3oct", 4, wh: 501, from: 91, to: 31)
        try add(q, "5oct", 6, wh: 366, from: 99, to: 56)
        let out = try CalibrationUpdater.update(db, nowMs: t0)
        XCTAssertEqual(out.calibration.ridesUsed, 3)
        XCTAssertEqual(out.ridesChanged, 0)
        let row = try XCTUnwrap(CalibrationQueries(db).current())
        XCTAssertEqual(row.id, CalibrationQueries.mainId)
        XCTAssertEqual(row.status, "learning")
        XCTAssertEqual(row.ridesUsed, 3)
        XCTAssertEqual(row.packAh, 16)
        let back = CalibrationUpdater.current(db)
        XCTAssertEqual(back.whPerPct, out.calibration.whPerPct, accuracy: 1e-9)
        XCTAssertEqual(back.status, .learning)
        XCTAssertEqual(try q.ride(id: "5oct")?.usedPct, 43)
    }

    func test_fiveRides_calibrated_rerunsRides_notSimulated_notLongGaps() throws {
        let db = try open()
        let q = RideQueries(db)
        for i in 0..<5 { try add(q, "g\(i)", i, wh: 8.4 * 40, from: 85, to: 45) }
        try add(q, "sim", 5, wh: 12 * 40, from: 85, to: 45, sim: true)
        try add(q, "gap", 6, wh: 100, from: 85, to: 45)
        let gap = try q.openGap(rideId: "gap", kind: "scooter", startT: 100_000)
        try q.closeGap(id: try XCTUnwrap(gap.id), endT: 250_000)   // 150 s phone mode
        try add(q, "open", 7, wh: 300, from: 85, to: 45, status: "recording")
        let out = try CalibrationUpdater.update(db, nowMs: t0)
        XCTAssertTrue(out.calibration.isCalibrated)
        XCTAssertEqual(out.verdicts["sim"], .rejected(.simulated))
        XCTAssertEqual(out.verdicts["gap"], .rejected(.gap))
        XCTAssertNil(out.verdicts["open"])
        XCTAssertEqual(try CalibrationQueries(db).current()?.status, "active")
        let g = try XCTUnwrap(q.ride(id: "g0"))
        XCTAssertEqual(g.usedPctMethod, "calibrated")
        XCTAssertEqual(g.usedPct ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(g.energyWhCal ?? 0, 8.4 * 40 / (8.4 / 7.68), accuracy: 1e-6)
        XCTAssertEqual(try q.ride(id: "sim")?.usedPctMethod, "rested")
        XCTAssertEqual(try q.ride(id: "gap")?.usedPctMethod, "rested")
        // running again changes nothing
        XCTAssertEqual(try CalibrationUpdater.update(db, nowMs: t0).ridesChanged, 0)
    }

    func test_sagAware_rideWithoutRestedEnd_usesTheNextStart() throws {
        let db = try open()
        let q = RideQueries(db)
        try add(q, "a", 0, wh: 8.4 * 40, from: 96, to: nil, lastLive: 50)
        var next = RideRecord(id: "b", startAt: t0 + 3_600_000 * 3)
        next.status = "ended"
        next.startRestPct = 56
        try q.save(next)
        let out = try CalibrationUpdater.update(db, nowMs: t0)
        XCTAssertEqual(out.verdicts["a"], .used(whPerPct: 8.4, dropPct: 40, endFromNextStart: true))
        XCTAssertEqual(out.calibration.ridesUsed, 1)
    }
}
