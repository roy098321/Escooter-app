import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// M1-05: phone takeover (G1) on top of the ride engine: the ~5 s wait (no switch for a 1-s blip), GPS speed as
/// the 3-s median, labelled; "~N% est." (T49, decision 5 fallback chain); gap rows; the odometer fills the
/// distance on reconnect; scooter-only totals; format change → phone mode (SC-04); the T99 speed warning on
/// scooter and GPS speed (SPD-46, SPD-46-GPS).
final class PhoneTakeoverTests: XCTestCase {
    // MARK: Helpers

    private func frame(_ t: Double, _ kmh: Double, amps: Double? = 8, batt: Int = 90, odo: Double = 100) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh
        f.currentA = amps
        f.batteryPct = batt
        f.odometerKm = odo
        f.voltage = 50
        return f
    }

    private func fix(_ t: Double, northM: Double = 0, kmh: Double? = 0) -> PhoneFix {
        PhoneFix(t: t, lat: 10 + northM / 111_320, lon: -30, hAccM: 5, speedMps: kmh.map { $0 / 3.6 } ?? -1)
    }

    /// Riding (Start ride by hand at 1 s), 20 km/h with motor power until `until`, GPS fixes every second.
    private func riding(until: Double = 10) -> (RideEngine, Double) {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(0.5, 0)), at: 0.5)
        e.handle(.startPressed, at: 1)
        var t = 1.0
        var north = 0.0
        while t <= until {
            e.handle(.frame(frame(t, 20)), at: t)
            if t == t.rounded() {
                north += 20 / 3.6
                e.handle(.fix(fix(t, northM: north, kmh: 20)), at: t)
            }
            t += 0.5
        }
        return (e, north)
    }

    private func scenario(_ id: String) throws -> SimStream {
        try XCTUnwrap(SyntheticScenario.all.first { $0.id == id }).build()
    }

    /// Ride 2 at 1 per second (F3) with the phone's own GPS + barometer (F4); faults relative to the start.
    private func rideTwoWithPhone(_ faults: (Double) -> [Fault] = { _ in [] }) throws -> SimStream {
        let text = try Fixtures.text("F3_ride2_merged.csv")
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == "F3" })
        let start = try XCTUnwrap(LogReader.mergedStartTimeOfDayS(text))
        let phone = try PhoneSource.events(locationText: Fixtures.text("F4_ride2_location.csv"),
                                           barometerText: Fixtures.text("F4_ride2_barometer.csv"),
                                           scooterStartTimeOfDayS: start)
        let scooter = try sim.events(from: text)
        let t0 = scooter.first?.t ?? 0
        return SimStream(scooter: FaultInjector.apply(faults(t0), to: scooter), phone: phone)
    }

    // MARK: The ~5 s wait

    func test_oneSecondBlip_noTakeover_scooterNumbersHeld() {
        var (e, _) = riding(until: 10)
        e.handle(.disconnected, at: 10.2)
        let during = e.liveInput(at: 10.8)
        XCTAssertTrue(during.scooterLinked, "a blip keeps the scooter numbers")
        XCTAssertEqual(during.scooterSpeedKmh ?? 0, 20, accuracy: 0.01)
        XCTAssertFalse(e.phoneMode(at: 10.8))
        var events = e.handle(.connected, at: 11)
        for t in stride(from: 11.0, through: 30, by: 0.5) { events += e.handle(.frame(frame(t, 20)), at: t) }
        XCTAssertFalse(events.contains { if case .phoneModeStarted = $0 { return true } else { return false } })
        XCTAssertTrue(e.ride?.gapList.isEmpty ?? false, "no gap row for a blip")
    }

    func test_takeoverAfter5s_gpsLabelled_estimate_gapClosedOnReconnect_odometerFills() throws {
        var (e, north) = riding(until: 10)
        var events = e.handle(.disconnected, at: 10.5)
        var builder = LiveStateBuilder()
        var t = 11.0
        while t <= 40 {
            north += 20 / 3.6
            events += e.handle(.fix(fix(t, northM: north, kmh: 20)), at: t)
            events += e.handle(.tick, at: t)
            let live = builder.update(e.liveInput(at: t))
            if t < 15.5 {
                XCTAssertFalse(e.phoneMode(at: t), "no takeover before 5 s (t \(t))")
                XCTAssertEqual(live.speedSource, .scooter, "held through the wait (t \(t))")
            } else {
                XCTAssertTrue(e.phoneMode(at: t), "phone mode after 5 s (t \(t))")
                XCTAssertEqual(live.speedSource, .gps)
                XCTAssertEqual(live.speedLabel, "GPS", "GPS label always set in phone mode")
                XCTAssertTrue(live.speedGreyed)
                XCTAssertTrue(live.batteryEstimated)
                XCTAssertTrue(live.batteryText.hasPrefix("~") && live.batteryText.hasSuffix("% est."), live.batteryText)
                XCTAssertEqual(live.speedKmh, 20)
            }
            t += 1
        }
        XCTAssertTrue(events.contains(.phoneModeStarted(seq: 1, at: 10.5, reason: .disconnected)), "gap from the drop")
        // T49: 90% − 3.0 %/km × ~0.17 km
        let est = try XCTUnwrap(e.estimatedBatteryPct(at: 40))
        XCTAssertLessThan(est, 90)
        XCTAssertGreaterThan(est, 89)
        // reconnect: the first valid frame closes the gap, the odometer fills the distance (M5)
        events = e.handle(.connected, at: 41)
        events += e.handle(.frame(frame(41.5, 20, odo: 100.2)), at: 41.5)
        XCTAssertTrue(events.contains(.phoneModeEnded(seq: 1, at: 41.5)))
        let gap = try XCTUnwrap(e.ride?.gapList.first)
        XCTAssertEqual(gap.startT, 10.5)
        XCTAssertEqual(gap.endT, 41.5)
        XCTAssertEqual(gap.odometerFilledM ?? 0, 200, accuracy: 0.5)
        XCTAssertEqual(e.ride?.distanceAfterTrimM ?? 0, 200, accuracy: 0.5, "distance from the odometer, not GPS")
        let back = builder.update(e.liveInput(at: 41.5))
        XCTAssertEqual(back.speedSource, .scooter, "scooter numbers back on the first valid frame")
        XCTAssertFalse(back.batteryEstimated)
    }

    func test_gpsSpeed_isThe3sMedian() {
        var e = RideEngine()
        e.handle(.fix(fix(10, kmh: 10)), at: 10)
        e.handle(.fix(fix(11, kmh: 50)), at: 11)
        e.handle(.fix(fix(12, kmh: 12)), at: 12)
        XCTAssertEqual(e.gpsMedianKmh(at: 12) ?? 0, 12, accuracy: 0.001, "one wild fix does not move the speed")
        XCTAssertNil(e.gpsMedianKmh(at: 30), "no fresh fix, no GPS speed")
    }

    func test_estimate_fallbackChain_decision5() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(0.5, 0, batt: 90, odo: 100)), at: 0.5)
        e.handle(.startPressed, at: 1)
        e.handle(.frame(frame(1.5, 20, batt: 90, odo: 100)), at: 1.5)
        XCTAssertEqual(e.pctPerKmForEstimate, RideEngine.defaultPctPerKm, "before 1 km: 3.0 %/km")
        e.handle(.frame(frame(2, 20, batt: 86, odo: 102)), at: 2)
        XCTAssertEqual(e.pctPerKmForEstimate, 2.0, accuracy: 0.001, "after 1 km: this ride's %/km")
        e.usualPctPerKm = 2.5
        XCTAssertEqual(e.pctPerKmForEstimate, 2.5, "usual %/km (median of the last 10 rides) wins")
    }

    func test_engineStateWithAGap_survivesJson() throws {
        var (e, north) = riding(until: 10)
        e.handle(.disconnected, at: 10.5)
        for t in stride(from: 11.0, through: 20, by: 1) {
            north += 20 / 3.6
            e.handle(.fix(fix(t, northM: north, kmh: 20)), at: t)
        }
        XCTAssertEqual(e.ride?.gapList.count, 1)
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(RideEngine.self, from: data)
        XCTAssertEqual(back, e)
    }

    // MARK: Scenarios

    func test_SPD46_onAbove45_stillOnAt44_clearsBelow43_noFlicker() throws {
        let r = EngineRunner.run(try scenario("SPD-46"), tailS: 5, collectLive: true)
        let changes = r.slowChanges
        XCTAssertEqual(changes.count, 2, "one on, one off: \(changes)")
        let on = try XCTUnwrap(changes.first)
        XCTAssertTrue(on.on)
        XCTAssertTrue((35...37).contains(on.t), "on just after passing 45 (\(on.t))")
        XCTAssertTrue(r.live.first { $0.t == 40 }?.state.slow ?? false, "still red at 44")
        let off = try XCTUnwrap(changes.last)
        XCTAssertFalse(off.on)
        XCTAssertTrue((50...52).contains(off.t), "clears below 43 (\(off.t))")
        XCTAssertTrue(r.live.allSatisfy { $0.state.speedSource == .scooter || $0.t > 90 }, "scooter speed, no takeover")
    }

    func test_SPD46_GPS_warningKeepsWorkingOnGpsSpeed_labelled() throws {
        let r = EngineRunner.run(try scenario("SPD-46-GPS"), tailS: 5, collectLive: true)
        let changes = r.slowChanges.filter { $0.t <= 130 }
        XCTAssertEqual(changes.count, 1, "on once, never flickers through the drop: \(changes)")
        XCTAssertEqual(r.phoneModeStarts.count, 1)
        let start = try XCTUnwrap(r.phoneModeStarts.first)
        XCTAssertEqual(start.at, 70, accuracy: 1)
        XCTAssertEqual(start.reason, .disconnected)
        for item in r.live where item.t >= 71 && item.t <= 74 {
            XCTAssertEqual(item.state.speedSource, .scooter, "held during the ~5 s wait (t \(item.t))")
            XCTAssertTrue(item.state.slow)
        }
        let phone = r.live.filter { $0.t >= 77 && $0.t <= 108 }
        XCTAssertFalse(phone.isEmpty)
        for item in phone {
            XCTAssertEqual(item.state.speedSource, .gps, "t \(item.t)")
            XCTAssertEqual(item.state.speedLabel, "GPS")
            XCTAssertTrue(item.state.slow, "red + SLOW on GPS speed (t \(item.t))")
            XCTAssertEqual(item.state.slowText, "SLOW")
            XCTAssertTrue(item.state.batteryEstimated, "~N% est. (t \(item.t))")
        }
        let end = try XCTUnwrap(r.phoneModeEnds.first)
        XCTAssertEqual(end.at, 110, accuracy: 1.5, "scooter numbers back on reconnect")
        let ride = try XCTUnwrap(r.ends.first?.ride ?? r.engine.ride)
        let gap = try XCTUnwrap(ride.gapList.first)
        XCTAssertEqual(gap.odometerFilledM ?? 0, 46 / 3.6 * 40, accuracy: 150, "odometer fills the gap")
    }

    func test_SC01_D7_disconnect60s_ride2_totalsScooterOnly_odometerFills() throws {
        let r = EngineRunner.run(try rideTwoWithPhone { [.disconnect(at: $0 + 724, durationS: 60)] })
        XCTAssertGreaterThanOrEqual(r.phoneModeStarts.count, 1)
        XCTAssertEqual(r.phoneModeEnds.count, 1)
        let end = try XCTUnwrap(r.ends.first)
        XCTAssertEqual(end.ride.gapList.count, 1, "one gap inside the ride")
        let gap = try XCTUnwrap(end.ride.gapList.first)
        XCTAssertEqual(gap.reason, .disconnected)
        XCTAssertEqual((gap.endT ?? 0) - gap.startT, 60, accuracy: 3)
        let samples = r.samples[end.ride.seq] ?? []
        let rel = gap.startT - end.ride.startT
        let inGap = samples.filter { $0.t > rel + 6 && $0.t < rel + 54 }
        XCTAssertFalse(inGap.isEmpty, "the path keeps going on GPS")
        XCTAssertTrue(inGap.allSatisfy { $0.speedKmh == nil && $0.currentA == nil && $0.lat != nil }, "GPS-only samples")
        let m = end.metrics(samples)
        XCTAssertEqual(m.distanceKm, 13.7, accuracy: 0.15, "the odometer fills the distance")
        XCTAssertLessThan(m.energyWhRaw, 322, "no energy is invented for the gap")
        XCTAssertGreaterThan(m.energyWhRaw, 322 * 0.9)
        XCTAssertGreaterThan(m.gapScooterS, 50)
    }

    func test_SC04_formatChange_switchesToPhoneMode() throws {
        let r = EngineRunner.run(try rideTwoWithPhone { [.corruptBytes(from: $0 + 700, to: $0 + 1_000, share: 0.3)] })
        let start = try XCTUnwrap(r.phoneModeStarts.first)
        XCTAssertEqual(start.reason, .formatChanged)
        let sampleT = (r.samples.values.flatMap { $0 })
        XCTAssertFalse(sampleT.isEmpty)
    }
}
