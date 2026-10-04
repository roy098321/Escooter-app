import XCTest
@testable import CorckieCore

/// TESTING §3 "Thresholds": Thresholds.swift matches CALC_SPEC §10.
final class ThresholdsTests: XCTestCase {
    private func docTable() throws -> [String: String] {
        var table: [String: String] = [:]
        for line in try Fixtures.text("thresholds.md").split(separator: "\n") where line.hasPrefix("| T") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // cells: "", ID, Threshold, Value, Used in, Kind, ""
            guard cells.count >= 6 else { continue }
            table[cells[1]] = cells[3]
        }
        return table
    }

    func test_thresholds_everyDocIdIsInCode() throws {
        let doc = try docTable()
        XCTAssertGreaterThanOrEqual(doc.count, 70, "the doc copy looks truncated")
        for (id, value) in doc {
            XCTAssertEqual(T.catalog[id], value, "\(id) differs between CALC_SPEC §10 and Thresholds.swift")
        }
        XCTAssertEqual(Set(T.catalog.keys), Set(doc.keys), "code has IDs the doc doesn't, or the other way round")
    }

    /// The typed constants must say the same as the doc's words for the values the code uses today.
    func test_thresholds_typedValuesMatchDocWords() {
        let checks: [(String, Double)] = [
            ("T01", T.t01WheelKmhPerUnit), ("T03", T.t03MaxSpeedStepKmhPerS),
            ("T04", T.t04MaxBatteryStepPct), ("T05", T.t05MinVoltage), ("T05", T.t05MaxVoltage),
            ("T06", T.t06MaxTempC), ("T07", T.t07FailedFrameShare * 100), ("T07", T.t07NoPacketAS),
            ("T10", T.t10AutostartKmh), ("T17", T.t17EndDisconnectedS), ("T20", T.t20EndStandstillS / 60),
            ("T28", T.t28GoodFixM), ("T29", T.t29GpsZeroKmh), ("T42", T.t42PackVoltage),
            ("T42", T.t42DefaultPackAh), ("T47", T.t47HotC), ("T47", T.t47VeryHotC), ("T99", T.t99SlowKmh), ("T99", T.t99ClearKmh),
            ("T101", T.t101SafetyMarginShare * 100), ("T102", T.t102PushingMaxKmh), ("T102", T.t102PushingS)
        ]
        for (id, value) in checks {
            let words = T.catalog[id] ?? ""
            let text = value == value.rounded() ? String(Int(value)) : String(value)
            XCTAssertTrue(words.contains(text), "\(id): \(text) not found in \"\(words)\"")
        }
    }
}
