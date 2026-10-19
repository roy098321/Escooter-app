import XCTest

/// P6-2 chunk 2b (R1-R6, D1-D10, C1-C4): the sentences the owner approved for deletion stay gone from the Rides, ride detail and Compare source text.
final class DeclutterRidesGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    func test_ridesListSentencesAreGone() throws {
        let list = try text("UI/Rides/RidesListView.swift")
        let gone = ["Kept apart so they do not clutter", "Pill(text: \"Latest\")", "header(\"Latest\")", "showCompare", "Text(\"Compare\")"]
        for g in gone { XCTAssertFalse(list.contains(g), "Rides list still has: \(g)") }
        XCTAssertTrue(list.contains("Sort by"))
        XCTAssertTrue(list.contains(".searchable("))
    }

    func test_rideDetailSentencesAreGone() throws {
        let detail = try text("UI/Rides/RideDetailView.swift")
        let gone = ["More info", "No GPS on this ride", "The numbers below come from the scooter", "Compare with another ride", "Download Ride Replay",
                    "Export CSV (one line per reading)", "Export GPX (Strava, Komoot)", "Not now", "Show less", "Anything different", "Tap Save route"]
        for g in gone { XCTAssertFalse(detail.contains(g), "Ride detail still has: \(g)") }
        XCTAssertTrue(detail.contains("Save as route?"))
        XCTAssertTrue(detail.contains("DisclosureGroup(\"More\""))
        XCTAssertTrue(detail.contains("Label(\"Export\""))
    }

    func test_compareSentencesAreGone() throws {
        let sheet = try text("UI/Rides/RideToolsSheets.swift")
        for g in ["Both rides on one map", "does not rank them", "The last column is this ride minus the other one"] {
            XCTAssertFalse(sheet.contains(g), "Compare still has: \(g)")
        }
        let map = try text("UI/Rides/CompareMapView.swift")
        for g in ["? \"dashed\" : \"solid\"", "from the start\")", "At the tapped point", "Tap the map for both rides"] {
            XCTAssertFalse(map.contains(g), "Compare map still has: \(g)")
        }
    }
}
