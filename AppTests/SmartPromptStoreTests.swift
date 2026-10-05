import CorckieCore
import Foundation
import GRDB
import XCTest

/// M4-05 / M4-06 on the real schema: the smart prompt on a made-up ride (answers change the ride, once a day), the Loaded tag, and the heat cards.
final class SmartPromptStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-prompt-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1")
    }

    func test_promptAskedThenAnswered() throws {
        let db = try open()
        let r = try InsightSeed.promptRide(db)
        let off = FactorSeed.utcOffsetMin
        let card = SmartPromptService.card(db, rideId: r.lastRideId, nowMs: r.nowMs, utcOffsetMin: off)
        XCTAssertNotNil(card)
        XCTAssertTrue(card?.text.contains("more battery than usual") ?? false)
        SmartPromptService.shown(db, rideId: r.lastRideId, nowMs: r.nowMs, utcOffsetMin: off)
        XCTAssertNotNil(SmartPromptService.card(db, rideId: r.lastRideId, nowMs: r.nowMs, utcOffsetMin: off))   // same ride: kept until answered
        try SmartPromptService.answer(db, rideId: r.lastRideId, .heavy, nowMs: r.nowMs)
        let a = try SmartPromptQueries(db).rideAnswer(r.lastRideId)
        XCTAssertEqual(a?.loadKg, 15)
        XCTAssertEqual(a?.loadLevel, "heavy")
        XCTAssertEqual(a?.promptAnswer, "heavy")
        XCTAssertNil(SmartPromptService.card(db, rideId: r.lastRideId, nowMs: r.nowMs, utcOffsetMin: off))
        XCTAssertEqual(SmartPromptService.answerCount(db, .heavy), 1)
    }

    func test_dismissTwicePauses() throws {
        let db = try open()
        let r = try InsightSeed.promptRide(db)
        let off = FactorSeed.utcOffsetMin
        SmartPromptService.dismiss(db, rideId: "x1", nowMs: r.nowMs)
        SmartPromptService.dismiss(db, rideId: "x2", nowMs: r.nowMs)
        XCTAssertEqual(SmartPromptService.state(db).pausedUntilMs, r.nowMs + 7 * 86_400_000)
        XCTAssertNil(SmartPromptService.card(db, rideId: r.lastRideId, nowMs: r.nowMs + 86_400_000, utcOffsetMin: off))
    }

    func test_tyresSoftLeavesTheRideOutAndMakesTyresDue() throws {
        let db = try open()
        let r = try InsightSeed.promptRide(db)
        let now = r.nowMs
        try MaintenanceQueries(db).insertMissing([MaintenanceRecord(id: "tyres", name: "Tyre pressure", intervalKm: 300, intervalDays: 14,
                                                                    lastDoneOdoKm: 100, lastDoneAt: now, notifiedAt: now)])
        try SmartPromptService.answer(db, rideId: r.lastRideId, .tyresSoft, nowMs: now)
        XCTAssertEqual(try SmartPromptQueries(db).rideAnswer(r.lastRideId)?.excluded, true)
        let tyres = try MaintenanceQueries(db).all().first
        XCTAssertNil(tyres?.notifiedAt)
        XCTAssertLessThanOrEqual(tyres?.lastDoneAt ?? now, now - 14 * 86_400_000)
    }

    func test_loadedTag() throws {
        let db = try open()
        let r = try InsightSeed.promptRide(db)
        try SmartPromptService.setLoad(db, rideId: r.lastRideId, level: .light, nowMs: r.nowMs)
        XCTAssertEqual(try SmartPromptQueries(db).rideAnswer(r.lastRideId)?.loadKg, 5)
        try SmartPromptService.setLoad(db, rideId: r.lastRideId, level: .custom, kg: 7.5, nowMs: r.nowMs)
        let x = try SmartPromptQueries(db).rideAnswer(r.lastRideId)
        XCTAssertEqual(x?.loadKg, 7.5)
        XCTAssertEqual(x?.loadLevel, "custom")
        try SmartPromptService.setLoad(db, rideId: r.lastRideId, level: .custom, kg: 400, nowMs: r.nowMs)   // not plausible: ignored
        XCTAssertEqual(try SmartPromptQueries(db).rideAnswer(r.lastRideId)?.loadKg, 7.5)
    }

    func test_hotRideGivesPeakAndHotDayCards() throws {
        let db = try open()
        let r = try InsightSeed.hotRide(db)
        let ranked = try InsightQueries(db).ranked(forRide: r.lastRideId, nowMs: r.nowMs + 60_000)
        XCTAssertEqual(ranked.top?.type, .heatPeak)
        XCTAssertEqual(ranked.top?.text, "Peak 93 \u{00B0}C \u{00B7} +68 \u{00B0}C")
        XCTAssertTrue(ranked.more.contains { $0.type == .heatHotDay })
        let stored = try InsightQueries(db).forRide(r.lastRideId).map(\.id)
        XCTAssertEqual(Set(stored).count, stored.count)
    }
}
