import XCTest

/// Hotfix 111.291126.09 (owner 24 Nov: after leaving a ride, rides would not open again). Source guards (Linux can't build the app):
/// list taps go through `open`, which clears a selection left over from the last page before setting the new one.
final class Hotfix09GuardTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func test_listTapsAlwaysOpenThePage() throws {
        for (path, ref) in [("App/UI/Rides/RidesListView.swift", "RideRoute"), ("App/UI/Routes/RoutesListView.swift", "RouteRef")] {
            let s = try source(path)
            XCTAssertTrue(s.contains("private func open(_ id: String)"), path)
            XCTAssertTrue(s.contains("selected = nil\n        DispatchQueue.main.async { selected = \(ref)(id: id) }"), "\(path): clear, then open")
            XCTAssertFalse(s.contains("Button { selected = \(ref)("), "\(path): no tap sets the selection directly")
        }
    }
}
