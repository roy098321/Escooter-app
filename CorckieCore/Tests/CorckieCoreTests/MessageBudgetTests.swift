import XCTest
@testable import CorckieCore

/// M1-07: live banner rules (C24 order, at most 2 at ride start, 8 s, queue of 2, tappable only below 5 km/h).
final class MessageBudgetTests: XCTestCase {
    func testPriorityOrderIsC24() {
        let order: [LiveBanner] = [.veryHot, .choicePoint, .disconnected, .noGps, .batteryTight, .hot,
                                   .sameRide, .starting, .destination, .headwind]
        XCTAssertEqual(order.sorted(), order)
        XCTAssertEqual(LiveBanner.disconnected.priority, LiveBanner.noGps.priority)
        XCTAssertEqual(LiveBanner.sameRide.priority, LiveBanner.starting.priority)
    }

    func testRideStartShowsAtMostTwoHighestFirst() {
        var q = BannerQueue()
        q.beginRide(messages: [.headwind, .destination, .batteryTight, .sameRide])
        XCTAssertEqual(q.droppedToSummary.sorted(), [.destination, .headwind])
        XCTAssertEqual(q.tick(at: 0, speedKmh: 0)?.banner, .batteryTight)
        XCTAssertEqual(q.tick(at: 8, speedKmh: 0)?.banner, .sameRide)
        XCTAssertNil(q.tick(at: 16, speedKmh: 0))
    }

    func testBannerLastsEightSeconds() {
        var q = BannerQueue()
        q.raise(.batteryTight, at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 20)?.banner, .batteryTight)
        XCTAssertEqual(q.tick(at: 7.9, speedKmh: 20)?.banner, .batteryTight)
        XCTAssertNil(q.tick(at: 8.0, speedKmh: 20))
    }

    func testTappableOnlyBelowFiveKmh() {
        var q = BannerQueue()
        q.raise(.batteryTight, at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 4.9)?.tappable, true)
        XCTAssertEqual(q.tick(at: 1, speedKmh: 5.0)?.tappable, false)
        XCTAssertEqual(q.tick(at: 2, speedKmh: 5.1)?.tappable, false)
        XCTAssertFalse(q.dismissCurrent(speedKmh: 5.1))
        XCTAssertNotNil(q.tick(at: 3, speedKmh: 5.1))
        XCTAssertTrue(q.dismissCurrent(speedKmh: 0))
        XCTAssertNil(q.tick(at: 4, speedKmh: 0))
    }

    func testHigherPriorityPreemptsAndTheOldOneWaits() {
        var q = BannerQueue()
        q.raise(.headwind, at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 20)?.banner, .headwind)
        q.raise(.choicePoint, at: 2)
        XCTAssertEqual(q.tick(at: 2, speedKmh: 20)?.banner, .choicePoint)
        XCTAssertEqual(q.tick(at: 10, speedKmh: 20)?.banner, .headwind)     // after the choice point's 8 s
        XCTAssertEqual(q.droppedToSummary, [])
    }

    func testLowerPriorityDoesNotPreempt() {
        var q = BannerQueue()
        q.raise(.hot, at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 20)?.banner, .hot)
        q.raise(.destination, at: 1)
        XCTAssertEqual(q.tick(at: 1, speedKmh: 20)?.banner, .hot)
        XCTAssertEqual(q.tick(at: 8, speedKmh: 20)?.banner, .destination)
    }

    func testQueueHoldsTwoAndDropsTheLeastImportant() {
        var q = BannerQueue()
        q.raise(.sameRide, at: 0)
        _ = q.tick(at: 0, speedKmh: 20)            // on screen
        q.raise(.headwind, at: 1)
        q.raise(.destination, at: 1)
        XCTAssertEqual(q.waitingCount, 2)
        q.raise(.batteryTight, at: 2)              // third waiting: the least important (headwind) drops
        XCTAssertEqual(q.waitingCount, 2)
        XCTAssertEqual(q.droppedToSummary, [.headwind])
        XCTAssertEqual(q.tick(at: 2, speedKmh: 20)?.banner, .batteryTight)    // outranks the one on screen
    }

    func testStickyBannersStayAndRankOverTimed() {
        var q = BannerQueue()
        q.setActive(.disconnected, true, at: 0)
        q.raise(.headwind, at: 1)
        for t in stride(from: 0.0, through: 60.0, by: 5.0) {
            XCTAssertEqual(q.tick(at: t, speedKmh: 20)?.banner, .disconnected)    // no 8 s limit
        }
        q.setActive(.disconnected, false, at: 61)
        XCTAssertEqual(q.tick(at: 61, speedKmh: 20)?.banner, .headwind)
    }

    func testChoicePointOutranksDisconnectedButVeryHotOutranksAll() {
        var q = BannerQueue()
        q.setActive(.disconnected, true, at: 0)
        q.raise(.choicePoint, at: 1)
        XCTAssertEqual(q.tick(at: 1, speedKmh: 20)?.banner, .choicePoint)
        q.setActive(.veryHot, true, at: 2)
        XCTAssertEqual(q.tick(at: 2, speedKmh: 20)?.banner, .veryHot)
    }

    func testHotOncePerRideAndVeryHotStaysUntilBelowHot() {
        var q = BannerQueue()
        q.beginRide(messages: [])
        q.feedHeat(tempC: 91, at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 20)?.banner, .hot)
        XCTAssertNil(q.tick(at: 8, speedKmh: 20))
        q.feedHeat(tempC: 85, at: 10)
        q.feedHeat(tempC: 92, at: 20)                                   // hot again: not announced again
        XCTAssertNil(q.tick(at: 20, speedKmh: 20))
        q.feedHeat(tempC: 101, at: 30)
        XCTAssertEqual(q.tick(at: 30, speedKmh: 20)?.banner, .veryHot)
        q.feedHeat(tempC: 95, at: 60)                                   // still above hot: stays
        XCTAssertEqual(q.tick(at: 100, speedKmh: 20)?.banner, .veryHot)
        q.feedHeat(tempC: 89, at: 120)
        XCTAssertNil(q.tick(at: 120, speedKmh: 20))
    }

    func testOnceOnlyMessagesDoNotRepeatInARide() {
        var q = BannerQueue()
        q.beginRide(messages: [])
        q.raise(.batteryTight, at: 0)
        _ = q.tick(at: 0, speedKmh: 20)
        _ = q.tick(at: 9, speedKmh: 20)
        q.raise(.batteryTight, at: 10)
        XCTAssertNil(q.tick(at: 10, speedKmh: 20))
        q.beginRide(messages: [])                                         // next ride: allowed again
        q.raise(.batteryTight, at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 20)?.banner, .batteryTight)
    }
}
