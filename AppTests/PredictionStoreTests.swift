import CorckieCore
import Foundation
import GRDB
import XCTest

/// T-00 part 2: the prediction log, shadow results and scenario facts in the database, and the v3 migration keeping data.
final class PredictionStoreTests: XCTestCase {
    private var folder: URL!
    private let start: Int64 = 1_800_000_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-pred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func openDB() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "pred-test")
    }

    private func seedRide(_ db: AppDatabase, id: String = "R1", routeId: String? = "RT") throws {
        try RideToolsSeed.ride(db, id: id, startAt: start)
        try db.writer.write { d in
            try d.execute(sql: """
                UPDATE ride SET routeId = ?, startRestPct = 84, endRestPct = 74, energyWhRaw = 50, totalS = 600, distanceM = 6000,
                                usedPct = 10, isSimulated = 0, kind = 'ride' WHERE id = ?
                """, arguments: [routeId, id])
        }
    }

    func test_migrationV3_onFrozenDatabase_keepsRows_andAddsTheTables() throws {
        let source = try XCTUnwrap(Bundle(for: PredictionStoreTests.self).url(forResource: "p4-foundation", withExtension: "sqlite"))
        let url = folder.appendingPathComponent("corckie.sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        let rides = try DatabaseQueue(path: url.path).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") }
        let db = try AppDatabase(url: url, build: "pred-test")
        XCTAssertEqual(db.migratedNow, ["v2", "v3", "v4"])
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ride") }, rides)
        for table in Migration0003.tables {
            XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }, 0)
        }
    }

    func test_log_sameNumberWithinTenMinutes_isStoredOnce() throws {
        let db = try openDB()
        let store = PredictionQueries(db)
        XCTAssertTrue(try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 600, at: start))
        XCTAssertFalse(try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 600, at: start + 60_000))
        XCTAssertTrue(try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 630, at: start + 120_000))
        XCTAssertTrue(try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 630, at: start + 20 * 60_000))
        XCTAssertTrue(try store.log(kind: PredictionKind.time, routeId: "OTHER", predicted: 600, at: start))
        XCTAssertEqual(try store.waiting().count, 4)
    }

    func test_afterRide_settlesPredictions_andStoresShadow() throws {
        let db = try openDB()
        try seedRide(db)
        let store = PredictionQueries(db)
        _ = try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 570, at: start - 60_000)
        _ = try store.log(kind: PredictionKind.battery, routeId: "RT", predicted: 5, at: start - 60_000)
        _ = try store.log(kind: PredictionKind.range, routeId: nil, predicted: 90, aux: 75, at: start + 10_000)
        _ = try store.log(kind: PredictionKind.calib, routeId: nil, predicted: 8, at: start + 10_000)
        _ = try store.log(kind: PredictionKind.time, routeId: "OTHER", predicted: 100, at: start - 60_000)
        try FieldKitService.afterRide(db, rideId: "R1", nowMs: start + 700_000)

        let all = try store.all()
        func actual(_ kind: String) -> Double? { all.first { $0.kind == kind && $0.rideId == "R1" }?.actual }
        XCTAssertEqual(actual(PredictionKind.time), 600)
        XCTAssertEqual(actual(PredictionKind.battery), 10)
        XCTAssertEqual(actual(PredictionKind.range) ?? 0, 45, accuracy: 1e-9)
        XCTAssertEqual(actual(PredictionKind.calib) ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(try store.waiting().map(\.routeId), ["OTHER"])

        let lines = FieldKitService.accuracyLines(db)
        XCTAssertEqual(lines.first { $0.kind == PredictionKind.time }?.n, 1)
        XCTAssertTrue(FieldKitService.accuracyText(db).contains("Q-C Today's time estimate"))

        let shadow = try store.shadowRows()
        XCTAssertTrue(shadow.contains { $0.rule == ShadowCalc.ruleStart && $0.variant == "2 km/h" && $0.isStandard })
        XCTAssertTrue(FieldKitService.shadowText(db).contains("Autostart speed"))
        XCTAssertFalse(FieldKitService.shadowText(db).contains("SLOW"), "the SLOW rule is gone (P-4)")
    }

    func test_afterRide_ignoresSimulatedRides_andShortHops() throws {
        let db = try openDB()
        try seedRide(db, id: "SIM")
        try db.writer.write { try $0.execute(sql: "UPDATE ride SET isSimulated = 1 WHERE id = 'SIM'") }
        let store = PredictionQueries(db)
        _ = try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 570, at: start - 60_000)
        try FieldKitService.afterRide(db, rideId: "SIM", nowMs: start + 700_000)
        XCTAssertEqual(try store.waiting().count, 1)
        XCTAssertTrue(try store.shadowRows().isEmpty)
    }

    func test_oldWaitingPredictions_areRemoved() throws {
        let db = try openDB()
        try seedRide(db)
        let store = PredictionQueries(db)
        _ = try store.log(kind: PredictionKind.range, routeId: nil, predicted: 10, at: start - 8 * 86_400_000)
        _ = try store.log(kind: PredictionKind.range, routeId: "x", predicted: 11, at: start - 86_400_000)
        try FieldKitService.afterRide(db, rideId: "R1", nowMs: start + 700_000)
        XCTAssertEqual(try store.waiting().count, 1)
    }

    func test_deletingARide_removesItsPredictionsAndShadow() throws {
        let db = try openDB()
        try seedRide(db)
        let store = PredictionQueries(db)
        _ = try store.log(kind: PredictionKind.time, routeId: "RT", predicted: 570, at: start - 60_000)
        try FieldKitService.afterRide(db, rideId: "R1", nowMs: start + 700_000)
        XCTAssertFalse(try store.all().isEmpty)
        XCTAssertFalse(try store.shadowRows().isEmpty)
        XCTAssertTrue(try RideQueries(db).delete(rideId: "R1"))
        XCTAssertTrue(try store.all().isEmpty)
        XCTAssertTrue(try store.shadowRows().isEmpty)
    }

    func test_scenarioVerdicts_fromRealRidesAndMarks() throws {
        let db = try openDB()
        try seedRide(db, routeId: nil)
        try db.writer.write { d in
            try d.execute(sql: "UPDATE ride SET wet = 'rain', startRestPct = 15, endReason = 'standstill', utcOffsetMin = 180 WHERE id = 'R1'")
            try d.execute(sql: "INSERT INTO charge (id, afterRideId) VALUES ('c1', 'R1')")
        }
        RideMarks.noteTrackingStarted(db, at: start - 1_000)
        RideMarks.add(db, RideMarks.lowPower, at: start + 5_000)
        RideMarks.add(db, RideMarks.lowPower, at: start + 20_000)           // within a minute: not added again
        XCTAssertEqual(RideMarks.list(db, RideMarks.lowPower), [start + 5_000])
        let ids = Set(FieldKitService.scenarioVerdicts(db).map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["p6rain", "p6lb", "p6left", "p6chg", "p6lpm", "p6pocket", "p6route"]), "\(ids)")
        XCTAssertFalse(ids.contains("p6load"))
    }

    func test_shadow_onARoute_storesTheGateDecisions() throws {
        let db = try openDB()
        for (i, id) in ["A", "B", "C", "D"].enumerated() {
            try RideToolsSeed.ride(db, id: id, startAt: start + Int64(i) * 86_400_000)
            try db.writer.write { d in
                try d.execute(sql: "UPDATE ride SET routeId = 'RT', totalS = 600, usedPct = 6, isSimulated = 0, kind = 'ride' WHERE id = ?", arguments: [id])
            }
        }
        try FieldKitService.afterRide(db, rideId: "D")
        let rows = try PredictionQueries(db).shadowRows()
        // D is the fourth ride of the route: the battery gate (5) is closed, the 4-ride shadow gate would be open
        let battery4 = rows.first { $0.rule == ShadowCalc.ruleGateBattery && $0.variant == "4 rides" }
        XCTAssertEqual(battery4?.differs, true)
        XCTAssertTrue(rows.contains { $0.rule == ShadowCalc.ruleDifferent })
    }

    func test_marks_keepOnlyTheNewest200() throws {
        let db = try openDB()
        for i in 0..<250 { RideMarks.add(db, RideMarks.screenOn, at: start + Int64(i) * 120_000) }
        let marks = RideMarks.list(db, RideMarks.screenOn)
        XCTAssertEqual(marks.count, RideMarks.keep)
        XCTAssertEqual(marks.last, start + 249 * 120_000)
    }
}
