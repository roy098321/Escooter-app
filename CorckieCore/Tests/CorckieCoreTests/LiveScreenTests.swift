import XCTest
@testable import CorckieCore

/// M1-12: the display rules of the live ride screen: Ready (D2), no tabs, SLOW, GPS / "~N% est." labels,
/// banners (one at a time, tappable only below 5 km/h), hold to end, the path.
final class LiveScreenTests: XCTestCase {
    private func riding(_ speed: Double?, phase: RidePhase = .riding, battery: Double? = 80, gps: Double? = nil,
                        linked: Bool = true, phone: Bool = false, temp: Double? = nil, noGpsS: Double = 0,
                        sameRide: Bool = false, format: Bool = false, est: Double? = nil, elapsed: Double? = 125) -> LiveInput {
        LiveInput(scooterSpeedKmh: linked ? speed : nil, gpsSpeedKmh: gps, scooterLinked: linked, scooterBatteryPct: battery,
                  estimatedBatteryPct: est, starting: phase == .starting, secondsWithoutGps: noGpsS, phase: phase,
                  scooterTempC: temp, phoneMode: phone, formatChanged: format, sameRideOffered: sameRide, rideElapsedS: elapsed)
    }

    // MARK: Ready (D2)

    func testReadyShowsMapBatterySpeedZeroNoClockNoStopButMayBeClosed() {
        var d = LiveScreenDriver()
        let s = d.update(riding(0, phase: .ready, elapsed: nil), at: 0)
        XCTAssertEqual(s.mode, .ready)
        XCTAssertEqual(s.tiles.speedKmh, 0)
        XCTAssertEqual(s.tiles.batteryText, "80%")
        XCTAssertFalse(s.showClock)
        XCTAssertFalse(s.showHoldToEnd)
        XCTAssertFalse(s.showNotRiding)
        XCTAssertTrue(s.canClose)
        XCTAssertNil(s.banner, "no banners before a ride")
    }

    func testReadyIgnoresHeatAndGpsChipsButKeepsOffline() {
        var d = LiveScreenDriver()
        var input = riding(0, phase: .ready, temp: 105, noGpsS: 60)
        input.mapOffline = true
        let s = d.update(input, at: 0)
        XCTAssertNil(s.banner)
        XCTAssertEqual(s.chips, [.offlineMap])
    }

    func testRideHasNoCloseButton() {
        var d = LiveScreenDriver()
        for phase in [RidePhase.starting, .riding] {
            let s = d.update(riding(10, phase: phase), at: 0)
            XCTAssertFalse(s.canClose, "no way out of a ride but hold to end")
            XCTAssertTrue(s.showHoldToEnd)
        }
    }

    func testCoverAndNoTabsRule() {
        XCTAssertTrue(LiveScreenLogic.coverShown(phase: .riding, readyRequested: false))
        XCTAssertTrue(LiveScreenLogic.coverShown(phase: .starting, readyRequested: false))
        XCTAssertTrue(LiveScreenLogic.coverShown(phase: .ready, readyRequested: true))
        XCTAssertFalse(LiveScreenLogic.coverShown(phase: .ready, readyRequested: false))
        XCTAssertFalse(LiveScreenLogic.coverShown(phase: .idle, readyRequested: false))
    }

    // MARK: Starting

    func testStartingShowsDotNotRidingAndClock() {
        var d = LiveScreenDriver()
        let s = d.update(riding(1, phase: .starting, elapsed: 4), at: 0)
        XCTAssertEqual(s.mode, .starting)
        XCTAssertTrue(s.tiles.showStartingDot)
        XCTAssertTrue(s.showNotRiding)
        XCTAssertEqual(s.clockText, "0:04")
        let r = d.update(riding(12), at: 1)
        XCTAssertFalse(r.tiles.showStartingDot)
        XCTAssertFalse(r.showNotRiding)
    }

    func testClockText() {
        XCTAssertEqual(LiveScreenLogic.clock(0), "0:00")
        XCTAssertEqual(LiveScreenLogic.clock(61.9), "1:01")
        XCTAssertEqual(LiveScreenLogic.clock(3725), "1:02:05")
        XCTAssertEqual(LiveScreenLogic.clock(nil), "0:00")
    }

    // MARK: Speed warning and labels

    func testSlowOnAbove45ClearsBelow43() {
        var d = LiveScreenDriver()
        let out = [44.9, 45.1, 44.0, 43.0, 42.9].enumerated().map { d.update(riding($0.element), at: Double($0.offset)).tiles.slow }
        XCTAssertEqual(out, [false, true, true, true, false])
    }

    func testSlowTextAndGpsSpeedIsGreyedAndLabelled() {
        var d = LiveScreenDriver()
        let s = d.update(riding(nil, gps: 46, linked: false, phone: true), at: 0)
        XCTAssertTrue(s.tiles.slow)
        XCTAssertEqual(s.tiles.slowText, "SLOW")
        XCTAssertEqual(s.tiles.speedLabel, "GPS")
        XCTAssertTrue(s.tiles.speedGreyed)
        XCTAssertTrue(s.dashedPath)
    }

    func testPhoneModeBatteryIsAnEstimate() {
        var d = LiveScreenDriver()
        let s = d.update(riding(nil, battery: 58, gps: 20, linked: false, phone: true, est: 55.2), at: 0)
        XCTAssertEqual(s.tiles.batteryText, "~55% est.")
        XCTAssertTrue(s.tiles.batteryEstimated)
        // scooter back: the real number, no label
        let back = d.update(riding(20, battery: 54), at: 1)
        XCTAssertEqual(back.tiles.batteryText, "54%")
        XCTAssertNil(back.tiles.speedLabel)
        XCTAssertFalse(back.dashedPath)
    }

    // MARK: Banners

    func testDisconnectedBannerStaysWhileInPhoneModeAndFormatChangedHasItsOwnText() {
        var d = LiveScreenDriver()
        var s = d.update(riding(nil, gps: 15, linked: false, phone: true), at: 0)
        XCTAssertEqual(s.banner?.banner, .disconnected)
        XCTAssertEqual(s.bannerText, "Scooter disconnected \u{00B7} reconnecting\u{2026}")
        s = d.update(riding(nil, gps: 15, linked: false, phone: true), at: 30)
        XCTAssertEqual(s.banner?.banner, .disconnected, "no 8-s limit while the condition lasts")
        s = d.update(riding(15), at: 31)
        XCTAssertNil(s.banner)

        var f = LiveScreenDriver()
        let fs = f.update(riding(nil, gps: 15, linked: false, phone: true, format: true), at: 0)
        XCTAssertEqual(fs.bannerText, "Scooter data format changed")
    }

    func testBannerTappableOnlyBelow5KmhAndNeverTwoAtOnce() {
        var d = LiveScreenDriver()
        _ = d.update(riding(0), at: 0)
        let fast = d.update(riding(30, temp: 91), at: 1)
        XCTAssertEqual(fast.banner?.banner, .hot)
        XCTAssertEqual(fast.banner?.tappable, false)
        XCTAssertFalse(d.tapBanner(speedKmh: 30), "taps do nothing while moving")
        XCTAssertEqual(d.update(riding(30, temp: 91), at: 2).banner?.banner, .hot)
        let stopped = d.update(riding(0, temp: 91), at: 3)
        XCTAssertEqual(stopped.banner?.tappable, true)
        XCTAssertTrue(d.tapBanner(speedKmh: 0))
        XCTAssertNil(d.update(riding(0, temp: 91), at: 4).banner, "hot is announced once per ride")
    }

    func testTimedBannerLeavesAfter8SecondsAndVeryHotWins() {
        var d = LiveScreenDriver()
        XCTAssertEqual(d.update(riding(20, temp: 91), at: 0).banner?.banner, .hot)
        XCTAssertNil(d.update(riding(20, temp: 91), at: 8.5).banner)
        let vh = d.update(riding(20, temp: 101), at: 9)
        XCTAssertEqual(vh.banner?.banner, .veryHot)
        XCTAssertEqual(d.update(riding(20, temp: 95), at: 100).banner?.banner, .veryHot, "stays until below hot")
        XCTAssertNil(d.update(riding(20, temp: 85), at: 101).banner)
    }

    func testNoGpsChipAfter10SecondsAndItsBannerReplacesTheChip() {
        var d = LiveScreenDriver()
        let early = d.update(riding(20, noGpsS: 9), at: 0)
        XCTAssertTrue(early.chips.isEmpty)
        XCTAssertFalse(early.dotGreyed)
        let late = d.update(riding(20, noGpsS: 10), at: 1)
        XCTAssertTrue(late.dotGreyed)
        XCTAssertEqual(late.banner?.banner, .noGps)
        XCTAssertFalse(late.chips.contains(.noGps), "one \"No GPS\" on screen, not two")
        XCTAssertNil(d.update(riding(20, noGpsS: 0), at: 2).banner)
    }

    func testSameRideBannerShowsYesNoUntilAnsweredAndNeverBlocksTheTiles() {
        var d = LiveScreenDriver()
        let s = d.update(riding(0, phase: .starting, sameRide: true), at: 0)
        XCTAssertEqual(s.banner?.banner, .sameRide)
        XCTAssertTrue(s.bannerIsSameRide)
        XCTAssertEqual(s.banner?.tappable, true)
        XCTAssertEqual(s.tiles.speedKmh, 0, "tiles are separate from the banner")
        // answered: the engine clears the offer
        let after = d.update(riding(0, phase: .starting, sameRide: false), at: 1)
        XCTAssertNil(after.banner)
    }

    // MARK: Hold to end

    func testHoldToEndNeedsTheFullSecond() {
        var h = HoldToEnd()
        XCTAssertFalse(h.completed(at: 5), "a tap that never began does nothing")
        h.begin(at: 10)
        XCTAssertEqual(h.progress(at: 10.5), 0.5, accuracy: 0.001)
        XCTAssertFalse(h.completed(at: 10.99))
        XCTAssertTrue(h.completed(at: 11.0))
        h.cancel()
        XCTAssertFalse(h.completed(at: 12), "released early")
        XCTAssertEqual(h.progress(at: 12), 0)
    }

    // MARK: Path

    func testPathBucketsAndDashedRuns() {
        XCTAssertEqual([5.0, 15, 25, 35, 45].map(LivePath.bucket(speedKmh:)), [0, 1, 2, 3, 4])
        var p = LivePath()
        let step = 10.0 / 111_320   // 10 m north
        p.add(lat: 10, lon: 20, speedKmh: 8, dashed: false)
        p.add(lat: 10 + step, lon: 20, speedKmh: 9, dashed: false)
        p.add(lat: 10 + 2 * step, lon: 20, speedKmh: 25, dashed: false)
        p.add(lat: 10 + 3 * step, lon: 20, speedKmh: 25, dashed: true)
        XCTAssertEqual(p.segments.map(\.bucket), [0, 2, 2])
        XCTAssertEqual(p.segments.map(\.dashed), [false, false, true])
        XCTAssertEqual(p.segments[1].coords.count, 2, "a new run starts at the end of the old one: no hole")
        // under 3 m: dropped
        p.add(lat: 10 + 3 * step + 1.0 / 111_320, lon: 20, speedKmh: 25, dashed: true)
        XCTAssertEqual(p.pointCount, 2 + 2 + 2)
        p.reset()
        XCTAssertEqual(p.pointCount, 0)
    }

    // MARK: From the real engine

    private func frame(_ t: Double, _ kmh: Double, temp: Double? = nil) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh
        f.currentA = 8
        f.batteryPct = 90
        f.odometerKm = 100
        f.voltage = 50
        f.temperatureC = temp
        return f
    }

    func testEngineFillsTheLiveInput() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(0.5, 0)), at: 0.5)
        XCTAssertEqual(e.liveInput(at: 0.6).phase, .ready)
        e.handle(.startPressed, at: 1)
        e.handle(.fix(PhoneFix(t: 1, lat: 10, lon: 20, hAccM: 5, speedMps: 5)), at: 1)
        e.handle(.frame(frame(1.5, 18, temp: 71)), at: 1.5)
        let i = e.liveInput(at: 2)
        XCTAssertTrue(e.rideActive)
        XCTAssertTrue([RidePhase.starting, .riding].contains(i.phase))
        XCTAssertEqual(i.scooterTempC, 71)
        XCTAssertEqual(i.lat, 10)
        XCTAssertEqual(i.rideElapsedS ?? -1, 1, accuracy: 0.01)
        XCTAssertFalse(i.phoneMode)
        e.handle(.disconnected, at: 3)
        let gone = e.liveInput(at: 9)
        XCTAssertTrue(gone.phoneMode, "after the ~5 s takeover wait")
        XCTAssertNil(gone.scooterTempC)
        var d = LiveScreenDriver()
        XCTAssertEqual(d.update(gone, at: 9).banner?.banner, .disconnected)
    }
}
