import XCTest

/// P6-2 chunk 2a (H1-H8, L1, L3, L4): the sentences the owner approved for deletion stay gone from the Home and live view source text.
final class DeclutterHomeGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    func test_homeSentencesAreGone() throws {
        let home = try text("UI/Home/HomeView.swift")
        let gone = ["Rides start only once the scooter is connected", "Rides also start on their own", "Goes onto the next ride when it starts",
                    "Load for the next ride\").font", "The arrival time shows on the ride screen", "Developer"]
        for g in gone { XCTAssertFalse(home.contains(g), "Home still has: \(g)") }
        XCTAssertTrue(home.contains("StatusPill("))
        XCTAssertTrue(home.contains(".fileImporter(isPresented: $pickingBackup"), "the backup banner opens the folder picker itself")
    }

    func test_liveViewSentencesAreGone() throws {
        let live = try text("UI/Live/LiveRideView.swift")
        XCTAssertFalse(live.contains("the ride starts when you move"))
        XCTAssertFalse(live.contains("min left"))
        XCTAssertTrue(live.contains("mappin.and.ellipse"), "B47: a neutral arrival icon, never a racing flag")
    }
}
