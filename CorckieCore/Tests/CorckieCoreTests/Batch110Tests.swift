import CorckieCore
import XCTest

/// Batch 10 guard tests (maintenance: fault recognition, maintenance screen, access, B97–B99). Logic in CorckieCore, plus checks on
/// the app's source text (Linux CI cannot build the app, like ThemeGuardTests).
final class Batch110Tests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: N10-16 · B97 Home logo

    /// The Home header is the C mark only: no name next to it (iOS 26 clipped it to a sliver); the name stays for VoiceOver
    func test_B97_homeHeaderIsTheMarkOnly() throws {
        let home = try text("UI/Home/HomeView.swift")
        XCTAssertTrue(home.contains("Image(\"HeaderMark\")"))
        XCTAssertFalse(home.contains("Text(\"CorckieApp\")"), "no visible name in the header")
        XCTAssertTrue(home.contains(".accessibilityLabel(\"CorckieApp\")"))
        let asset = appFolder.appendingPathComponent("Resources/Assets.xcassets/HeaderMark.imageset/HeaderMark@3x.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path))
    }

    // MARK: N10-17 · B98 grey rows

    /// Rows inside a List never get the N7-13 scroll fade (there the phase never reaches identity, so every row sat at 0.55)
    func test_B98_noScrollFadeOnListRows() throws {
        for path in ["UI/Rides/RidesListView.swift", "UI/Routes/RoutesListView.swift", "UI/Routes/PlacesView.swift"] {
            XCTAssertFalse(try text(path).contains(".scrollReactive()"), path)
        }
    }

    // MARK: N10-18 · B99 colour strip

    /// The ride's colour strip is a rounded bar set in from the row edge, so the zoom clip can't shave it into a crescent
    func test_B99_colourStripIsABar() throws {
        let rides = try text("UI/Rides/RidesListView.swift")
        guard let start = rides.range(of: "private func placeStrip") else { return XCTFail("placeStrip missing") }
        let body = String(rides[start.lowerBound...].prefix(900))
        XCTAssertFalse(body.contains("Capsule()"), "a capsule is cut into a crescent by the rounded clip")
        XCTAssertTrue(body.contains("RoundedRectangle(cornerRadius: 2"))
        XCTAssertTrue(body.contains(".padding(.leading, 4)"), "set in from the zoom clip's corner")
    }
}
