import XCTest
@testable import CorckieCore

/// F-32 (P-5): every build ships a What's new entry; the card shows once per build, never during a ride.
final class WhatsNewTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func entries() throws -> [WhatsNewEntry] {
        try WhatsNew.decode(try Data(contentsOf: root.appendingPathComponent("App/Resources/WhatsNew.json")))
    }

    /// The newest entry is this build's version (project.yml MARKETING_VERSION): a build without its card fails CI
    func testTheNewestEntryIsThisBuild() throws {
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let line = yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION") } ?? ""
        let version = line.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
        let list = try entries()
        XCTAssertEqual(list.first?.version, version, "WhatsNew.json must start with this build's entry")
        XCTAssertEqual(list.first?.title, "What's new \u{00B7} \(ReleaseName.code(version))")
        for e in list {
            XCTAssertTrue((3...4).contains(e.items.count), "\(e.version): 3 or 4 items on the card")
            XCTAssertFalse(e.full.isEmpty)
            XCTAssertTrue(ReleaseName.isValid(e.version))
        }
        XCTAssertEqual(Set(list.map(\.version)).count, list.count, "one entry per build")
    }

    func testShowsOncePerBuildNeverDuringARide() throws {
        let list = try entries()
        let v = list.first?.version ?? ""
        XCTAssertTrue(WhatsNew.shouldShow(current: v, lastSeen: nil, riding: false, entries: list))
        XCTAssertFalse(WhatsNew.shouldShow(current: v, lastSeen: nil, riding: true, entries: list), "waits for the next launch")
        XCTAssertFalse(WhatsNew.shouldShow(current: v, lastSeen: v, riding: false, entries: list), "once per build")
        XCTAssertFalse(WhatsNew.shouldShow(current: "199.010199.00", lastSeen: v, riding: false, entries: list), "no card without an entry")
        XCTAssertEqual(list.first?.smallerFixesLine, "+ 26 smaller changes")
    }
}
