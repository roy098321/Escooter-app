import XCTest
@testable import CorckieCore

/// M1-00b: the Checks screen's progress bars and step ticks.
final class CheckProgressTests: XCTestCase {
    func test_timed_showsTimeLeftAndFraction() {
        let bar = CheckProgress.timed(elapsed: 40, total: 240)
        XCTAssertEqual(bar.label, "3:20 left")
        XCTAssertEqual(bar.fraction, 40.0 / 240.0, accuracy: 1e-9)
        XCTAssertEqual(CheckProgress.timed(elapsed: 240, total: 240).label, "done")
        XCTAssertEqual(CheckProgress.timed(elapsed: 999, total: 240).fraction, 1)
        XCTAssertEqual(CheckProgress.timed(elapsed: -5, total: 240).fraction, 0)
        XCTAssertEqual(CheckProgress.timed(elapsed: 0.2, total: 600).label, "10:00 left")
    }

    func test_counted_clampsAndLabels() {
        XCTAssertEqual(CheckProgress.counted(have: 12, need: 20, noun: "fixes").label, "12 of 20 fixes")
        XCTAssertEqual(CheckProgress.counted(have: 50, need: 20, noun: "fixes").fraction, 1)
        XCTAssertEqual(CheckProgress.counted(have: 0, need: 100, noun: "packets").fraction, 0)
    }

    func test_stepped_reportsPosition() {
        let bar = CheckProgress.stepped(index: 3, of: 7, name: "Backup + restore")
        XCTAssertEqual(bar.label, "Step 3 of 7 · Backup + restore")
        XCTAssertEqual(bar.fraction, 2.0 / 7.0, accuracy: 1e-9)
    }

    func test_b9_ticksInTheOwnersOrder() {
        let half = CheckProgress.b9(armed: true, locked: true, disconnected: false, reconnected: false, withoutOpening: false)
        XCTAssertEqual(half.map(\.done), [true, true, false, false, false])
        XCTAssertEqual(CheckProgress.tally(half), "2 of 5")
        XCTAssertEqual(half.count, 5)
    }

    func test_otherStepLists_haveTheDocumentedLength() {
        XCTAssertEqual(CheckProgress.c5(restarted: true, startedInBackground: false, scooterConnected: false, passed: false).count, 4)
        XCTAssertEqual(CheckProgress.c6(scooterWoke: true, sent: true, delivered: false).map(\.done), [true, true, false])
        XCTAssertEqual(CheckProgress.c7(lowPower: true, woke: false, enoughData: false).count, 3)
    }
}
