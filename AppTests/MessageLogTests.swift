import Foundation
import GRDB
import XCTest

/// M1-10: message_log rows (sent / dropped with a reason) on the real schema.
final class MessageLogTests: XCTestCase {
    func test_sentAndDroppedRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-msg-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1")
        let log = MessageLogQueries(db)
        try log.add(type: "going_for_a_ride", channel: "notification", at: 1_000, droppedReason: nil)
        try log.add(type: "going_for_a_ride", channel: "notification", at: 2_000, droppedReason: "app on screen")
        try log.add(type: "weekly", channel: "notification", at: 3_000, droppedReason: nil)
        let rows = try log.entries(type: "going_for_a_ride")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].sentAt, 1_000)
        XCTAssertNil(rows[0].droppedReason)
        XCTAssertNil(rows[1].sentAt)
        XCTAssertEqual(rows[1].droppedReason, "app on screen")
        XCTAssertEqual(try log.entries(type: "weekly").count, 1)
    }
}
