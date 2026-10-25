import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// B54: a ride's start and end use settled battery readings (the boot 100 % is never a ride's value) and a battery that
/// "went up" during a ride shows the start value once. Made-up packets through the real decoder and pipeline.
final class SettledBatteryTests: XCTestCase {
    private func packet(_ pct: Int, kmh: Double = 0) -> [UInt8] {
        var v = PacketEncoder.Values()
        v.batteryPct = pct
        v.speedKmh = kmh
        v.odometerKm = 100
        return PacketEncoder.packetA(v)
    }

    func test_B54_bootReadingNeverReachesTheFrames() {
        var p = ScooterPipeline()
        p.handle(TimedScooterEvent(t: 0, event: .connected))
        var seen: [Int?] = []
        for (i, pct) in [100, 100, 100, 99, 99, 99, 99].enumerated() {
            p.handle(TimedScooterEvent(t: Double(i) + 0.5, event: .packet(packet(pct))))
            seen.append(p.frame?.batteryPct)
        }
        XCTAssertFalse(seen.contains(100), "the boot 100 % is not handed on: \(seen)")
        XCTAssertEqual(seen.last, 99)
        XCTAssertEqual(p.batterySettle.notifyPct, 99)
    }

    func test_B54_reallyFullScooter_isBelievedAfterTheHold() {
        var p = ScooterPipeline()
        p.handle(TimedScooterEvent(t: 0, event: .connected))
        for i in 0..<10 { p.handle(TimedScooterEvent(t: Double(i), event: .packet(packet(100)))) }
        XCTAssertEqual(p.frame?.batteryPct, 100)
    }

    func test_B54_rideStartedAtPowerOn_startsAtTheSettledValue() {
        var feed = RideFeed()
        feed.scooter(TimedScooterEvent(t: 0, event: .connected))
        // boot 100 for 2 s, then the real 99; riding from 1 s
        for i in 0..<40 {
            let t = Double(i) * 0.5
            feed.scooter(TimedScooterEvent(t: t, event: .packet(packet(t < 2 ? 100 : 99, kmh: t >= 1 ? 15 : 0))))
        }
        XCTAssertNotNil(feed.engine.ride)
        XCTAssertEqual(feed.engine.ride?.firstBatteryPct, 99, "not the boot 100")
    }

    func test_B54_summary_endAboveStart_showsTheStartOnce() {
        XCTAssertEqual(RideSummaryBuilder.batteryText(99, 100), "99%")
        XCTAssertEqual(RideSummaryBuilder.batteryText(99, 97), "99% \u{2192} 97%")
        XCTAssertEqual(RideSummaryBuilder.batteryText(99, 99), "99% \u{2192} 99%")
    }
}
