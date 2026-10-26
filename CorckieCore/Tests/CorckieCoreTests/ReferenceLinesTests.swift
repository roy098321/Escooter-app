import XCTest
@testable import CorckieCore

/// Hotfix 01 (H4): the owner's examples for the Stats chart's dashed lines.
final class ReferenceLinesTests: XCTestCase {
    func test_ownerExamples() {
        XCTAssertEqual(ReferenceLines.steps(top: 13, metric: .km), [5, 10, 15])
        XCTAssertEqual(ReferenceLines.steps(top: 99, metric: .saved), [30, 60, 90])
        XCTAssertEqual(ReferenceLines.steps(top: 0, metric: .km), [])
        XCTAssertEqual(ReferenceLines.steps(top: 7, metric: .rides), [2, 4, 6])
        XCTAssertEqual(ReferenceLines.steps(top: 28, metric: .km), [10, 20, 30], "the bug case: top bar 28 km")
    }

    func test_wholeMetricsNeverGetADecimalStep() {
        for top in [1.0, 2, 4, 5, 7, 8, 11, 17, 40, 99, 140] {
            for metric in [PastWeeksMetric.rides, .saved] {
                for v in ReferenceLines.steps(top: top, metric: metric) {
                    XCTAssertEqual(v, v.rounded(), "\(metric) \(top): \(v)")
                }
            }
        }
        XCTAssertEqual(ReferenceLines.steps(top: 1, metric: .rides), [1])
        XCTAssertEqual(ReferenceLines.steps(top: 2, metric: .rides), [1, 2])
    }

    func test_timeUsesNiceMinutesAndHours() {
        XCTAssertEqual(ReferenceLines.steps(top: 45, metric: .time), [15, 30, 45])
        XCTAssertEqual(ReferenceLines.steps(top: 100, metric: .time), [30, 60, 90])
        XCTAssertEqual(ReferenceLines.steps(top: 200, metric: .time), [60, 120, 180])
    }

    func test_theTopLineIsAboutAtTheTopBar_andTheScaleHoldsIt() {
        for top in [0.6, 3, 13, 28, 47, 99, 260, 1_234] {
            let lines = ReferenceLines.steps(top: top, metric: .km)
            XCTAssertEqual(lines.count, 3)
            XCTAssertEqual(lines[2], top, accuracy: top * 0.4, "\(top): \(lines)")
            XCTAssertGreaterThanOrEqual(ReferenceLines.domainTop(top: top, lines: lines), lines[2], "every line sits on the bars' scale")
        }
    }
}
