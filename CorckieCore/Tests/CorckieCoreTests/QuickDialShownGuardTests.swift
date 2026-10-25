import XCTest

/// B55 (owner screenshot 21 Oct): Home showed no quick dial at all while connected. The row is never hidden any more and a failed read
/// is logged; checked against the app's source text on Linux CI.
final class QuickDialShownGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    func test_B55_quickDialRowIsNeverHidden_andFailuresAreLogged() throws {
        let home = try text("UI/Home/HomeView.swift")
        XCTAssertFalse(home.contains("shownChips.isEmpty && shownQuick.isEmpty"), "the quick dial must not hide when the lists are empty")
        XCTAssertTrue(home.contains("if m.state != .riding { whereToRow"), "shown whenever no ride is on")
        XCTAssertTrue(home.contains("QuickDialLoader.lastFailure"), "a failed load is logged")
        let loader = try text("Routes/QuickDialLoader.swift")
        XCTAssertFalse(loader.contains("(try? store.places())"), "the places read is not swallowed")
        XCTAssertFalse(loader.contains("(try? store.routes())"), "the routes read is not swallowed")
    }
}
