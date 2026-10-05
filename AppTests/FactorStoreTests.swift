import CorckieCore
import Foundation
import GRDB
import XCTest

/// M4-02: the factors engine on the real schema (migration v1, no schema change): a made-up windy commute (ocean
/// coordinates) gets its columns from the cached weather and its effects into `factor_effect`; pattern W fills later.
final class FactorStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-factor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1")
    }

    private let now = FactorSamples.t0 + 60 * FactorSamples.day

    func test_commute_columnsAndEffects_endToEnd() throws {
        let db = try open()
        let ids = try FactorSeed.commute(db)
        let report = try FactorUpdater.update(db, rideId: ids.last, nowMs: now)
        XCTAssertEqual(report.ridesFilled, 24)
        XCTAssertEqual(report.withWeather, 24)
        let q = FactorQueries(db)
        let head = try XCTUnwrap(try q.input(rideId: ids[0]))
        XCTAssertEqual(try XCTUnwrap(head.headwindKmh), 12, accuracy: 0.5)
        XCTAssertEqual(head.windLevel, "light")
        XCTAssertEqual(head.wet, "dry")
        XCTAssertEqual(head.dayType, "workday")
        XCTAssertEqual(head.rushHour, true)
        XCTAssertEqual(head.holidayWeek, false)
        XCTAssertEqual(try XCTUnwrap(head.airTempC), 27, accuracy: 1e-9)
        let tail = try XCTUnwrap(try q.input(rideId: ids[2]))
        XCTAssertEqual(try XCTUnwrap(tail.headwindKmh), -12, accuracy: 0.5)

        let route = FactorEffects.forRoute(db, routeId: "seed-route")
        let w = try XCTUnwrap(route.first { $0.factorId == "W1" && $0.level == "head" && $0.quantity == .time })
        XCTAssertTrue(w.passesGate, "\(w)")
        XCTAssertEqual(try XCTUnwrap(w.timeEffectS), 90, accuracy: 9)
        XCTAssertEqual(w.n, 8)
        let rush = try XCTUnwrap(route.first { $0.factorId == "T1" && $0.quantity == .used })
        XCTAssertEqual(try XCTUnwrap(rush.usedEffectPct), 1.0, accuracy: 0.1)
        XCTAssertFalse(FactorEffects.forPooled(db).isEmpty)
        // what does not pass keeps its counts but no value
        let none = try XCTUnwrap(FactorEffects.forPooled(db).first { $0.factorId == "W3" && $0.quantity == .time })
        XCTAssertFalse(none.passesGate)
        XCTAssertNil(none.effect)

        let ex = try XCTUnwrap(FactorEffects.forRide(db, rideId: ids[0], nowMs: now))
        XCTAssertFalse(ex.weatherMissing)
        XCTAssertEqual(Set(ex.items.map(\.factorId)), ["W1", "T1"])
        XCTAssertNotNil(ex.actualTimeS)
        XCTAssertEqual(try XCTUnwrap(FactorEffects.developerLine(db, rideId: ids[0])).hasPrefix("Factors: headwind 12 km/h"), true)
    }

    func test_patternW_weatherArrivesLater() throws {
        let db = try open()
        let ids = try FactorSeed.commute(db, n: 3, withWeather: false)
        try FactorUpdater.update(db, rideId: ids[0], nowMs: now)
        let q = FactorQueries(db)
        let r = try XCTUnwrap(try q.input(rideId: ids[0]))
        XCTAssertNil(r.headwindKmh)
        XCTAssertNil(r.windLevel)
        XCTAssertNil(r.wet)
        XCTAssertEqual(r.dayType, "workday", "the day columns never wait for weather")
        XCTAssertEqual(try q.pending(limit: 40).count, 3, "still waiting for weather")
        XCTAssertTrue(try XCTUnwrap(FactorEffects.forRide(db, rideId: ids[0], nowMs: now)).weatherMissing)
        XCTAssertEqual(FactorEffects.developerLine(db, rideId: ids[0]), "Factors: weather not there yet · workday · rush hour")
        // the weather arrives (same rows the seed would write): the next run fills the rides
        let start = r.startAt
        var rows: [WeatherRow] = []
        var h = OutsideTime.floorHour(start) - OutsideRules.rainWindowMs
        while h <= OutsideTime.floorHour(start) + 3 * OutsideTime.hourMs {
            rows.append(WeatherRow(cellKey: GeoCell.key(lat: FactorSeed.lat0, lon: FactorSeed.lon0), hourAt: h, source: "test", kind: .forecast,
                                   windKmh: 20, windFromDeg: 0, precipMm: 1, airTempC: 30, fetchedAt: start))
            h += OutsideTime.hourMs
        }
        try OutsideQueries(db).save(weather: rows)
        let report = try FactorUpdater.refreshPending(db, nowMs: now)
        XCTAssertEqual(report.withWeather, 1)
        let filled = try XCTUnwrap(try q.input(rideId: ids[0]))
        XCTAssertEqual(try XCTUnwrap(filled.headwindKmh), 20, accuracy: 0.5)
        XCTAssertEqual(filled.windLevel, "moderate")
        XCTAssertEqual(filled.wet, "light")
        XCTAssertEqual(try q.pending(limit: 40).count, 2)
    }

    func test_effects_roundTrip_andSimulatedRidesStayApart() throws {
        let db = try open()
        let q = FactorQueries(db)
        let e = [
            FactorEffect(factorId: "W1", level: "head", scope: .route, routeId: "A", quantity: .time, effect: 90, n: 8, nWithout: 8, confidence: 0.7, gate: .passed),
            FactorEffect(factorId: "W1", level: "head", scope: .route, routeId: "A", quantity: .used, effect: nil, n: 4, nWithout: 8, confidence: -1, gate: .notEnoughRides),
            FactorEffect(factorId: "L1", level: "perKgUncertain", scope: .pooled, routeId: nil, quantity: .used, effect: 0.004, n: 6, nWithout: 10, confidence: 0.3, gate: .passed),
            FactorEffect(factorId: "W1+W3", level: "head+wet", scope: .pooled, routeId: nil, quantity: .time, effect: nil, n: 2, nWithout: 9, confidence: -4, gate: .combined)
        ]
        try q.replaceEffects(e, computedAt: 5)
        XCTAssertEqual(try q.effects(), e)
        XCTAssertEqual(try q.effects(scope: .route, routeId: "A").count, 2)
        XCTAssertEqual(try q.effectCount().passed, 2)
        // replaced, not added
        try q.replaceEffects(Array(e.prefix(1)), computedAt: 6)
        XCTAssertEqual(try q.effects().count, 1)

        // simulated rides: route effects only, never pooled with real ones
        let ids = try FactorSeed.commute(db)
        try db.writer.write { d in try d.execute(sql: "UPDATE ride SET isSimulated = 1") }
        try FactorUpdater.update(db, rideId: ids[0], nowMs: now)
        XCTAssertTrue(FactorEffects.forPooled(db).allSatisfy { $0.n == 0 && $0.nWithout == 0 })
        XCTAssertTrue(FactorEffects.forRoute(db, routeId: "seed-route").contains { $0.passesGate })
    }

    func test_readOnly_doesNothing_andNoRides_noCrash() throws {
        let db = try open()
        let report = try FactorUpdater.update(db, rideId: "missing", nowMs: now)
        XCTAssertEqual(report.ridesFilled, 0)
        XCTAssertNil(FactorEffects.forRide(db, rideId: "missing"))
        XCTAssertTrue(FactorEffects.forPooled(db).allSatisfy { !$0.passesGate })
    }
}
