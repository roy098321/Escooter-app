import XCTest
@testable import CorckieCore

/// R3 / B64: Home shows the last reading and its time; the ride's resting reading wins over a dip seen at the same stop.
final class LastReadingTests: XCTestCase {
    private let min: Int64 = 60_000

    func testTheRidesRestingReadingWinsAtTheSameStop() {
        let ride = BatteryReading(pct: 66, ms: 1_000 * min)
        let seen = BatteryReading(pct: 62, ms: 1_002 * min)
        XCTAssertEqual(LastReading.pick(seen: seen, rideEnd: ride), ride)
    }

    func testALaterReadingWins() {
        let ride = BatteryReading(pct: 66, ms: 1_000 * min)
        let seen = BatteryReading(pct: 90, ms: 1_200 * min)
        XCTAssertEqual(LastReading.pick(seen: seen, rideEnd: ride), seen)
        XCTAssertEqual(LastReading.pick(seen: nil, rideEnd: ride), ride)
        XCTAssertEqual(LastReading.pick(seen: seen, rideEnd: nil), seen)
        XCTAssertNil(LastReading.pick(seen: nil, rideEnd: nil))
    }

    func testTheWords() {
        // 07:49 local in UTC+2 = 05:49 UTC
        let r = BatteryReading(pct: 66, ms: (5 * 60 + 49) * min)
        XCTAssertEqual(LastReading.text(r, utcOffsetMin: 120), "66% \u{00B7} 07:49")
        XCTAssertEqual(PlugAlert.default.targetText, "Charge to 100%")
        XCTAssertEqual(PlugAlert.range(15).targetText, "Charge to 15 km")
    }
}
