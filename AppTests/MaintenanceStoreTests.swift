import Foundation
import GRDB
import XCTest

/// M3-06: maintenance rows, the odometer and the notifications-today count on the real schema.
final class MaintenanceStoreTests: XCTestCase {
    private func open() throws -> (AppDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-maint-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1"), folder)
    }

    func test_insertMissing_keepsEditedRowsAndSaveRoundTrips() throws {
        let (db, folder) = try open()
        defer { try? FileManager.default.removeItem(at: folder) }
        let q = MaintenanceQueries(db)
        let a = MaintenanceRecord(id: "tyres", name: "Tyre pressure", intervalKm: 300, intervalDays: 14, lastDoneOdoKm: 10, lastDoneAt: 1_000, notifiedAt: nil)
        try q.insertMissing([a])
        var edited = a
        edited.lastDoneOdoKm = 99
        edited.notifiedAt = 5_000
        try q.save(edited)
        try q.insertMissing([a, MaintenanceRecord(id: "brakes", name: "Brakes", intervalKm: 500, intervalDays: nil, lastDoneOdoKm: 10, lastDoneAt: 1_000, notifiedAt: nil)])
        let rows = try q.all()
        XCTAssertEqual(rows.map(\.id), ["tyres", "brakes"])
        XCTAssertEqual(rows[0].lastDoneOdoKm, 99)
        XCTAssertEqual(rows[0].notifiedAt, 5_000)
    }

    func test_odometer_nilWithoutRides() throws {
        let (db, folder) = try open()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(try MaintenanceQueries(db).odometerKm())
    }

    func test_notificationsSentToday_countsOnlyBudgetedOnesOfTheLocalDay() throws {
        let (db, folder) = try open()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = MessageLogQueries(db)
        let day: Int64 = 20_000 * 86_400_000
        try log.add(type: "maintenance", channel: "notification", at: day + 3_600_000, droppedReason: nil)
        try log.add(type: "weekly", channel: "notification", at: day + 7_200_000, droppedReason: nil)
        try log.add(type: "leave_by", channel: "notification", at: day + 8_000_000, droppedReason: nil)
        try log.add(type: "going_for_a_ride", channel: "notification", at: day + 9_000_000, droppedReason: nil)
        try log.add(type: "maintenance", channel: "notification", at: day + 9_500_000, droppedReason: "quiet hours")
        try log.add(type: "maintenance", channel: "notification", at: day - 1_000, droppedReason: nil)
        let q = MaintenanceQueries(db)
        XCTAssertEqual(try q.notificationsSentToday(nowMs: day + 43_200_000, utcOffsetMin: 0), 2)
        // in UTC+3 the local day starts at 21:00 UTC the day before, so the row 1 s before midnight UTC is today as well
        XCTAssertEqual(try q.notificationsSentToday(nowMs: day + 43_200_000, utcOffsetMin: 180), 3)
    }
}
