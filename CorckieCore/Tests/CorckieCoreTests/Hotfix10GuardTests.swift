import XCTest

/// Hotfix 111.291126.10 (owner 24 Nov: End ride on the lock-screen card left the card up). Source guards (Linux can't build the app).
final class Hotfix10GuardTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func test_endRideButton_closesTheCardItself() throws {
        let s = try source("Shared/RideActivity/RideIntents.swift")
        let start = try XCTUnwrap(s.range(of: "struct EndRideIntent")).upperBound
        let end = try XCTUnwrap(s.range(of: "struct KeepGoingIntent")).lowerBound
        XCTAssertTrue(s[start..<end].contains("Activity<ScooterActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }"))
    }

    func test_noRide_closesACardLeftFromBeforeARelaunch() throws {
        let s = try source("App/Adapters/ScooterActivityController.swift")
        XCTAssertTrue(s.contains("(state == nil && leftOver)"))
    }
}
