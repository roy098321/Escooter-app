import XCTest
@testable import CorckieCore

/// B56 / B56b: the battery % flip filter and its per-scooter auto-detect. All on made-up readings.
final class BatteryFilterTests: XCTestCase {
    /// 100, 99, 100, 99 … once a second
    private func flipping(_ n: Int, high: Int = 100) -> [Int] { (0..<n).map { $0 % 2 == 0 ? high : high - 1 } }

    func test_B56_flippingScooter_turnsTheFilterOn_andShowsTheLowerOfThePair() {
        var f = BatteryFilter()
        var out: [Int] = []
        for (i, pct) in flipping(80).enumerated() { out.append(f.reading(pct, at: Double(i))) }
        XCTAssertTrue(f.detector.filterOn)
        XCTAssertGreaterThan(f.detector.flipShare, 0.9)
        // once on, the value never goes back up to 100
        XCTAssertEqual(Set(out.suffix(40)), [99])
    }

    func test_B56b_cleanScooter_isUntouched() {
        var f = BatteryFilter()
        var raw: [Int] = []
        var pct = 90
        for i in 0..<400 {
            if i % 10 == 0 { pct -= 1 }
            raw.append(pct)
        }
        let out = raw.enumerated().map { f.reading($0.element, at: Double($0.offset)) }
        XCTAssertFalse(f.detector.filterOn)
        XCTAssertEqual(out, raw, "a scooter that doesn't flip is used as it is")
    }

    func test_B56_downAtOnce_upOnlyOnPlusTwoOrPlusOneHeld60s() {
        var f = BatteryFilter(detector: Self.onDetector())
        XCTAssertEqual(f.reading(80, at: 0), 80)
        XCTAssertEqual(f.reading(79, at: 1), 79, "down at once")
        XCTAssertEqual(f.reading(80, at: 2), 79, "+1 is not believed yet")
        XCTAssertEqual(f.reading(80, at: 61), 79)
        XCTAssertEqual(f.reading(80, at: 62), 80, "+1 held for 60 s is believed (charging)")
        XCTAssertEqual(f.reading(82, at: 63), 82, "+2 at once")
        XCTAssertEqual(f.reading(81, at: 64), 81)
        XCTAssertEqual(f.reading(80, at: 65), 80, "a value below the pair takes it down")
        XCTAssertEqual(f.reading(81, at: 66), 80)
        XCTAssertEqual(f.reading(80, at: 67), 80, "a flip back cancels the pending rise")
        XCTAssertEqual(f.reading(81, at: 100), 80, "the 60 s start again")
    }

    func test_B56b_historySurvivesAConnection_andJSON() {
        var f = BatteryFilter()
        for (i, pct) in flipping(60).enumerated() { _ = f.reading(pct, at: Double(i)) }
        let stored = BatteryFlipDetector.parse(f.detector.json)
        XCTAssertEqual(stored.changes, f.detector.changes)
        XCTAssertTrue(stored.filterOn)
        var next = BatteryFilter(detector: stored)
        next.newConnection()
        XCTAssertEqual(next.reading(100, at: 0), 100, "the first reading of a connection is taken")
        XCTAssertEqual(next.reading(99, at: 1), 99)
        XCTAssertEqual(next.reading(100, at: 2), 99, "filtered from the first flip of the new connection")
        XCTAssertFalse(BatteryFlipDetector.parse(nil).filterOn)
        XCTAssertFalse(BatteryFlipDetector.parse("garbage").filterOn)
    }

    func test_B56b_windowKeepsTheLast200Changes() {
        var d = BatteryFlipDetector()
        for i in 0..<500 { d.reading(i % 2 == 0 ? 50 : 49) }
        XCTAssertEqual(d.changes, BatteryFlipDetector.window)
        // then a long clean stretch: the old flips roll out and the filter goes off
        for p in stride(from: 100, to: 0, by: -1) { d.reading(p); d.reading(p) }
        for p in stride(from: 100, to: 0, by: -1) { d.reading(p) }
        XCTAssertFalse(d.filterOn)
    }

    func test_B56_pipelineHandsOnTheFilteredValue() {
        var p = ScooterPipeline()
        var d = BatteryFlipDetector()
        for i in 0..<60 { d.reading(i % 2 == 0 ? 100 : 99) }
        p.setBatteryDetector(d)
        p.handle(TimedScooterEvent(t: 0, event: .connected))
        XCTAssertTrue(p.batteryFilter.detector.filterOn)
    }

    private static func onDetector() -> BatteryFlipDetector {
        var d = BatteryFlipDetector()
        for i in 0..<60 { d.reading(i % 2 == 0 ? 100 : 99) }
        d.newConnection()
        return d
    }
}
