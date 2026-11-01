import XCTest

/// Batch 102: source guards for app code that Linux cannot compile (read as text).
final class Batch102GuardTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// R4 + B68: the charging Live Activity only shows things that move by themselves: a countdown (system timer text) and a
    /// battery-shaped fill (system progress timer) with 25 / 50 / 75 % marks; no % number (it froze) and no clock time as the
    /// compact text.
    func test_chargeLiveActivityTicksByItself() throws {
        let w = try source("Widgets/ChargeLiveActivity.swift")
        XCTAssertTrue(w.contains("Text(timerInterval:"), "countdown is a system timer")
        XCTAssertTrue(w.contains("countsDown: true"), "it counts down")
        XCTAssertTrue(w.contains("ProgressView(timerInterval:"), "the fill is a system timer")
        XCTAssertTrue(w.contains("[0.25, 0.5, 0.75]"), "marks at 25 / 50 / 75 %")
        XCTAssertTrue(w.contains("struct BatteryFill"), "battery-shaped fill")
        XCTAssertFalse(w.contains("pct(context.state)") || w.contains("pct(state)"), "no frozen % number")
        let compact = try XCTUnwrap(w.range(of: "compactTrailing:")).upperBound
        let minimal = try XCTUnwrap(w.range(of: "minimal:")).lowerBound
        XCTAssertFalse(String(w[compact..<minimal]).contains("style: .time"), "the Dynamic Island shows a countdown, not a clock time")
        let attrs = try source("Shared/ChargeActivity/ChargeActivityAttributes.swift")
        XCTAssertTrue(attrs.contains("var targetAt: Date?"), "the countdown can run to the rider's target")
    }

    /// Batch 102 (FIN-2 item 6): ride detail works like Replay: Replay's strip, controls and dot, from the same Core pieces
    func test_rideDetailWorksLikeReplay() throws {
        let strip = try source("App/UI/Rides/RideReplayStrip.swift")
        XCTAssertTrue(strip.contains("ReplayTrack.from(") && strip.contains("ComparePlayback(") && strip.contains("TimeChart("), "Replay's pieces")
        XCTAssertTrue(strip.contains("ReplayView.speeds"), "the same 1x / 5x / 20x")
        let detail = try source("App/UI/Rides/RideDetailView.swift")
        XCTAssertTrue(detail.contains("RideReplayStrip(rideId:"), "the strip is in ride detail")
        XCTAssertTrue(detail.contains("ReplayDotMark()"), "the dot moves on the ride map")
    }

    /// Note 15: hold-to-hide is gone from the ride graph chips
    func test_graphChipsHaveNoHoldToHide() throws {
        let graph = try source("App/UI/Rides/RideGraphView.swift")
        XCTAssertFalse(graph.contains(".contextMenu"), "no hold menu on the chips")
        XCTAssertTrue(graph.contains("arrow.left.arrow.right"), "the \u{21C4} button")
    }
}
