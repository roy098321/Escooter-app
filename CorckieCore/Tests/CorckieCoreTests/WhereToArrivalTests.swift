import XCTest
@testable import CorckieCore

/// B58: the arrival clock of Where to? is leaving now plus the ride time, never the clock of the moment the list was loaded.
final class WhereToArrivalTests: XCTestCase {
    private func ms(_ h: Int, _ m: Int) -> Int64 { Int64((1_790_000_000 / 86_400 * 86_400 + h * 3600 + m * 60)) * 1000 }

    func test_B58_arrivalIsNowPlusTheRideTime_notTheLoadTime() {
        let loadedAt = ms(15, 54)
        let shownAt = ms(21, 16)
        XCTAssertEqual(WhereTo.arriveText(timeS: 31 * 60, nowMs: loadedAt, utcOffsetMin: 0), "16:25", "the owner's screenshot: computed at 15:54")
        XCTAssertEqual(WhereTo.arriveText(timeS: 31 * 60, nowMs: shownAt, utcOffsetMin: 0), "21:47", "shown at 21:16 it says 21:47")
        XCTAssertEqual(WhereTo.arriveText(timeS: 20 * 60, nowMs: ms(23, 50), utcOffsetMin: 60), "1:10", "across midnight, with the rider's offset")
    }

    func test_B58_chipsCarryTheRideTime() {
        let rides = (0..<5).map { i in
            RouteRideStats(rideId: "r\(i)", startAt: ms(8, 0) - Int64(i + 1) * 86_400_000, totalS: 600, distanceM: 3_000, avgMovingMps: 5, usedPct: 4)
        }
        let chips = WhereTo.chips([WhereToInput(routeId: "a", title: "Work", toName: "Work", rides: rides)], nowMs: ms(8, 0), utcOffsetMin: 0)
        XCTAssertEqual(chips.first?.timeS != nil, chips.first?.arriveText != nil, "a chip with an arrival carries its ride time")
        if let t = chips.first?.timeS, let text = chips.first?.arriveText {
            XCTAssertEqual(WhereTo.arriveText(timeS: t, nowMs: ms(8, 0), utcOffsetMin: 0), text, "the same clock as the chip at load time")
        }
    }
}
