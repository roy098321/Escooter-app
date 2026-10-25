import XCTest
@testable import CorckieCore

/// Note 11: the draggable ride review card: full / default / one line / hidden with a lip.
final class RideCardLayoutTests: XCTestCase {
    // iPhone 15: 852 pt tall, 59 status bar, 34 home indicator → 759 safe area; top bar + row + legend end at ~170
    private let height = 759.0, inset = 59.0, controls = 170.0, bar = 90.0

    private func tops() -> [CardDetent: Double] {
        Dictionary(uniqueKeysWithValues: CardDetent.allCases.map {
            ($0, RideCardLayout.top($0, height: height, topInset: inset, controlsBottom: controls, bottomReserve: bar))
        })
    }

    func testFourHeightsInOrder() {
        let t = tops()
        XCTAssertEqual(t[.full], 178)
        XCTAssertLessThan(t[.full]!, t[.standard]!)
        XCTAssertLessThan(t[.standard]!, t[.line]!)
        XCTAssertLessThan(t[.line]!, t[.hidden]!)
        XCTAssertEqual(t[.hidden], height, "hidden: only the lip shows")
        XCTAssertEqual(t[.line]!, height - bar - RideCardLayout.lineHeight, accuracy: 0.01)
        // B52: at the default height the map keeps ~55 % of the screen
        XCTAssertEqual(t[.standard]! + inset + RideCardLayout.overlap, (height + inset) * 0.55, accuracy: 0.5)
    }

    func testTheRowAndLegendStayVisibleAtFullHeight() {
        XCTAssertGreaterThan(tops()[.full]!, controls)
    }

    func testSnapGoesToTheNearestHeight() {
        let t = tops()
        XCTAssertEqual(RideCardLayout.snap(predictedTop: t[.standard]! + 30, tops: t), .standard)
        XCTAssertEqual(RideCardLayout.snap(predictedTop: 100, tops: t), .full)
        XCTAssertEqual(RideCardLayout.snap(predictedTop: t[.line]! + 10, tops: t), .line)
        XCTAssertEqual(RideCardLayout.snap(predictedTop: height + 200, tops: t), .hidden, "a hard flick down hides it")
    }

    func testStepsAndLine() {
        XCTAssertEqual(CardDetent.hidden.taller, .line)
        XCTAssertEqual(CardDetent.standard.taller, .full)
        XCTAssertEqual(CardDetent.full.shorter, .standard)
        XCTAssertEqual(CardDetent.line.shorter, .hidden)
        XCTAssertEqual(RideCardLayout.line(time: "19 min", distance: "8.0 km", topSpeed: "32 km/h"), "19 min \u{00B7} 8.0 km \u{00B7} 32 km/h")
        XCTAssertEqual(RideCardLayout.line(time: "19 min", distance: "8.0 km", topSpeed: "\u{2013}"), "19 min \u{00B7} 8.0 km")
    }

    func testSmallScreenStillOrders() {
        let small = CardDetent.allCases.map { RideCardLayout.top($0, height: 647, topInset: 20, controlsBottom: 170, bottomReserve: 90) }
        XCTAssertEqual(small, small.sorted())
        XCTAssertEqual(RideCardLayout.bottomCover(standardTop: 400, height: 800), 0.5, accuracy: 0.001)
    }
}
