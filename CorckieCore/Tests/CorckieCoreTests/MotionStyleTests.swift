import CorckieCore
import XCTest

/// Batch 6 guard: Reduce Motion turns the springs into fades.
final class MotionStyleTests: XCTestCase {
    func test_N6_reduceMotionTurnsSpringsIntoFades() {
        XCTAssertEqual(MotionStyle.pick(reduceMotion: false), .spring)
        XCTAssertEqual(MotionStyle.pick(reduceMotion: true), .fade)
        XCTAssertLessThanOrEqual(MotionStyle.fadeS, 0.25)
    }
}
