import XCTest
@testable import CorckieCore

final class RideCheckRulesTests: XCTestCase {
    private func ride(_ id: String, at: Int64 = 1_760_000_000_000, total: Double = 1200, samples: Int = 240,
                      reason: String? = "held", sim: Bool = false) -> RideFacts {
        RideFacts(id: id, startAtMs: at, endReason: reason, isSimulated: sim, totalS: total, distanceM: 5000,
                  odoStartKm: 100, odoEndKm: 105, topSpeedMps: 7, sampleCount: samples)
    }

    private func verdict(_ id: String, _ list: [RideCheckVerdict]) -> RideCheckVerdict? { list.first { $0.id == id } }

    func test_noRealRidesGivesNothing() {
        XCTAssertTrue(RideCheckRules.evaluate([]).isEmpty)
        XCTAssertTrue(RideCheckRules.evaluate([ride("a", sim: true)]).isEmpty)
    }

    func test_x1PassesWhenFullySampledAndFailsWithGaps() {
        XCTAssertEqual(verdict("x1", RideCheckRules.evaluate([ride("a")]))?.result, .pass)
        XCTAssertEqual(verdict("x1", RideCheckRules.evaluate([ride("a", samples: 150)]))?.result, .fail)
    }

    func test_x2NeedsTwoRidesOnOneDay() {
        XCTAssertNil(verdict("x2", RideCheckRules.evaluate([ride("a")])))
        let two = RideCheckRules.evaluate([ride("a"), ride("b", at: 1_760_000_000_000 + 3_600_000)])
        XCTAssertEqual(verdict("x2", two)?.result, .pass)
    }

    func test_s3WithinThreePercent() {
        XCTAssertEqual(verdict("s3", RideCheckRules.evaluate([ride("a")]))?.result, .pass)
        var off = ride("a")
        off.distanceM = 4000
        XCTAssertEqual(verdict("s3", RideCheckRules.evaluate([off]))?.result, .fail)
    }

    func test_scooterOffAndRecordedChecks() {
        let list = RideCheckRules.evaluate([ride("a", reason: "scooterOff")])
        XCTAssertEqual(verdict("e2m", list)?.result, .pass)
        XCTAssertEqual(verdict("w4", list)?.result, .info)
        XCTAssertEqual(verdict("b9m", list)?.result, .info)
        XCTAssertEqual(verdict("s2", list)?.result, .info)
        XCTAssertEqual(verdict("s5", list)?.result, .pass)
    }

    func test_shortHopsAndDiscardedNeverCount() {
        var hop = ride("h")
        hop.kind = "shortHop"
        XCTAssertTrue(RideCheckRules.evaluate([hop]).isEmpty)
    }
}

/// M1-16: every check ID in the on-device list is unique (read from the app source on Linux CI), and the
/// P4 results stay readable because no P4 ID is dropped.
final class CheckIdTests: XCTestCase {
    func test_everyCheckIdIsUnique() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Diagnostics/Checks.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?:CheckItem\(id: |\bm\()"([A-Za-z0-9]+)""#)
        let ns = text as NSString
        let ids = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        XCTAssertGreaterThan(ids.count, 100, "the whole M1 list is in Checks.swift")
        let dupes = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(dupes, [], "duplicate check IDs")
        for p4 in ["h1", "a1", "b1", "c1", "d1", "e1", "e8", "f1", "g1", "q1", "u16", "d10"] {
            XCTAssertTrue(ids.contains(p4), "P4 check \(p4) must stay")
        }
    }
}
