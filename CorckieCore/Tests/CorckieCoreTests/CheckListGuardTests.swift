import XCTest

/// T-01 (one check list for everything): the on-device list is read from the app source on Linux CI, so a check without an ⓘ guide,
/// a duplicate ID, a dead guide or a dead "Run all automatic" ID fails the build.
final class CheckListGuardTests: XCTestCase {
    private let diagnostics = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Diagnostics")

    private func source(_ name: String) throws -> String {
        try String(contentsOf: diagnostics.appendingPathComponent(name), encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String, group: Int = 1, options: NSRegularExpression.Options = []) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: group)) }
    }

    private func checkIds() throws -> [String] {
        try matches(#"(?:CheckItem\(id: |\bm\()"([A-Za-z0-9]+)""#, in: try source("Checks.swift"))
    }

    /// guide id -> the text of its entry (up to the next entry)
    private func guideEntries() throws -> [(id: String, body: String)] {
        let text = try source("CheckGuide.swift")
        let regex = try NSRegularExpression(pattern: #"(?m)^        "([A-Za-z0-9]+)": CheckGuide\("#)
        let ns = text as NSString
        let found = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [(String, String)] = []
        for (i, m) in found.enumerated() {
            let end = i + 1 < found.count ? found[i + 1].range.location : ns.length
            out.append((ns.substring(with: m.range(at: 1)), ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))))
        }
        return out
    }

    func test_everyCheckHasAnInfoGuide_andNoGuideIsDead() throws {
        let ids = Set(try checkIds())
        let guides = try guideEntries()
        let guideIds = guides.map(\.id)
        XCTAssertGreaterThan(ids.count, 200)
        XCTAssertEqual(ids.subtracting(guideIds).sorted(), [], "checks without an ⓘ guide")
        XCTAssertEqual(Set(guideIds).subtracting(ids).sorted(), [], "guides of checks that no longer exist")
        XCTAssertEqual(Dictionary(grouping: guideIds, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted(), [], "two guides for one check")
    }

    func test_everyGuideHasWhatItProvesStepsAndAPlace() throws {
        for (id, body) in try guideEntries() {
            XCTAssertTrue(body.contains("proves: \""), "\(id): no 'what it proves'")
            XCTAssertTrue(body.range(of: #"steps: \[[^\]]"#, options: .regularExpression) != nil, "\(id): no steps")
            XCTAssertTrue(body.range(of: #"place: \.(noScooter|scooterHome|ride|passive)\)"#, options: .regularExpression) != nil, "\(id): no place")
        }
    }

    func test_checkIdsAreUnique() throws {
        let ids = try checkIds()
        XCTAssertEqual(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted(), [])
    }

    func test_runAllAutomaticIds_areRealChecks_andNeverRideOrOwnerChecks() throws {
        let ids = Set(try checkIds())
        let runner = try source("AutoRunner.swift")
        guard let range = runner.range(of: "enum AutomaticChecks") else { return XCTFail("AutomaticChecks missing") }
        let automatic = try matches(#""([A-Za-z0-9]+)""#, in: String(runner[range.lowerBound...]))
        XCTAssertGreaterThan(automatic.count, 60)
        XCTAssertEqual(Set(automatic).subtracting(ids).sorted(), [], "Run all automatic names a check that does not exist")
        XCTAssertEqual(Dictionary(grouping: automatic, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted(), [])
        let places = Dictionary(uniqueKeysWithValues: try guideEntries().map { entry -> (String, Bool) in (entry.id, entry.body.contains("place: .ride)")) })
        XCTAssertEqual(automatic.filter { places[$0] == true }, [], "a check that needs a real ride cannot be in Run all automatic")
    }

    func test_realRideChecks_areMarkedOnARide() throws {
        let places = Dictionary(uniqueKeysWithValues: try guideEntries().map { entry -> (String, Bool) in (entry.id, entry.body.contains("place: .ride)")) })
        for id in ["x1", "x2", "s2", "s3", "s5", "e2m", "e3m", "w4", "b9m", "c8", "q1", "d10", "bt1", "bt2", "rt13", "mf1", "mi3", "mx1", "mk1", "mk2",
                   "mq1", "mq2", "p6lb", "p6rain", "p6night", "p6gps", "p6load", "p6route", "p6lpm", "p6left", "p6chg", "p6pocket"] {
            XCTAssertEqual(places[id], true, "\(id) needs a real ride and must be marked On a ride")
        }
    }

    func test_everyGroupUsedByAnItemIsInTheGroupList() throws {
        let text = try source("Checks.swift")
        let declared = try matches(#"static let ([A-Za-z0-9]+) = "[^"]+"\n"#, in: text)
        guard let groupsLine = try matches(#"static let groups = \[([^\]]+)\]"#, in: text).first else { return XCTFail("groups list missing") }
        let listed = Set(groupsLine.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let used = try matches(#"(?:group: |\bm\("[A-Za-z0-9]+", )([A-Za-z0-9]+)[,)]"#, in: text)
        for g in Set(used) where declared.contains(g) {
            XCTAssertTrue(listed.contains(g), "group \(g) is used by a check but missing from CheckList.groups")
        }
        XCTAssertFalse(listed.isEmpty)
    }
}
