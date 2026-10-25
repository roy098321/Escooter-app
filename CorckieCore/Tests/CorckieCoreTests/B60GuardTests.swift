import XCTest

/// B60 (owner 22 Oct): Home's background map has no parked-scooter pin; the Scooter tab keeps its Parked row and map.
final class B60GuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    func test_homeMapHasNoParkedPin_scooterTabKeepsIt() throws {
        let home = try String(contentsOf: appFolder.appendingPathComponent("UI/Home/HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("MapBackdrop(map: true, parked: nil, parkedPreview: nil)"), "Home's map backdrop gets no parked spot")
        let scooter = try String(contentsOf: appFolder.appendingPathComponent("UI/Scooter/ScooterTabView.swift"), encoding: .utf8)
        XCTAssertTrue(scooter.contains("parkedRow"), "the Scooter tab keeps its Parked row")
    }
}
