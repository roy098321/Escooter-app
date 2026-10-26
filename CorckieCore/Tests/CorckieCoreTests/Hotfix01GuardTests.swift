import XCTest

/// Hotfix 01 (owner, 25 Oct): the ride maps showed one shade for the whole route because each run was stroked with a SwiftUI
/// `LinearGradient` (laid across a box, not along the line). The map strokes must use a plain `Gradient` (option A).
final class Hotfix01GuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func source(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    func test_mapStrokesUsePlainGradient_notLinearGradient() throws {
        let path = try source("UI/Shared/GradientPath.swift")
        XCTAssertTrue(path.contains("static func gradient(_ run: GradientRun) -> Gradient {"), "the run's stroke is a plain Gradient")
        XCTAssertFalse(path.contains("-> LinearGradient"), "no LinearGradient for map strokes")
        XCTAssertFalse(path.contains("LinearGradient(stops:"), "no LinearGradient built from the route's colour stops")
        let replay = try source("UI/Rides/ReplayView.swift")
        XCTAssertTrue(replay.contains("gradient: Gradient)]"), "Replay strokes its runs with a plain Gradient")
        XCTAssertFalse(replay.contains("gradient: LinearGradient"), "Replay never strokes with a LinearGradient")
    }

    func test_routeLineLabHasThreeWays() throws {
        let lab = try source("UI/Developer/RouteLineLab.swift")
        XCTAssertTrue(lab.contains("MKGradientPolylineRenderer"), "C uses Apple's gradient line")
        XCTAssertTrue(lab.contains("lineCap: .butt"), "B is short pieces with butt caps")
        XCTAssertTrue(lab.contains("GradientPath.gradient("), "A is the app's own default")
        let dev = try source("UI/Developer/DeveloperView.swift")
        XCTAssertTrue(dev.contains("RouteLineLab()"), "the lab is in Developer")
    }
}
