import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// M1-04: stops (M3, T23–T25), ride end (M2 A, A2, B, C, low battery), auto-off, pushing / walking stretch
/// (D3, T102) with "battery ran out" (T80), Same ride (T21) and M36, recovery after a relaunch (SC-14), and
/// the hand-off to the ride metrics (`RideSample.moving`, stop rows) with the golden rides.
final class RideEngineEndTests: XCTestCase {
    // MARK: Helpers

    private func frame(_ t: Double, _ kmh: Double, amps: Double? = 0, batt: Int = 90, odo: Double = 100,
                       off: Bool = false) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh
        f.currentA = amps
        f.batteryPct = batt
        f.odometerKm = odo
        f.voltage = 50
        f.shuttingDown = off
        return f
    }

    private func fix(_ t: Double, northM: Double = 0, kmh: Double? = 0) -> PhoneFix {
        PhoneFix(t: t, lat: 10 + northM / 111_320, lon: -30, hAccM: 5, speedMps: kmh.map { $0 / 3.6 } ?? -1)
    }

    /// Riding (Start ride by hand at 1 s), then at 20 km/h with motor power until `until`.
    private func riding(until: Double = 10) -> RideEngine {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(0.5, 0)), at: 0.5)
        e.handle(.startPressed, at: 1)
        var t = 1.0
        while t <= until {
            e.handle(.frame(frame(t, 20, amps: 8)), at: t)
            t += 0.5
        }
        return e
    }

    private func stream(_ id: String) throws -> SimStream {
        try XCTUnwrap(SyntheticScenario.all.first { $0.id == id }).build()
    }

    private func fixture(_ id: String, _ file: String, faults: [Fault] = []) throws -> SimStream {
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == id })
        let events = try sim.events(from: Fixtures.text(file))
        let start = events.first?.t ?? 0
        let shifted = faults.map { f -> Fault in
            if case let .shutdown(at) = f { return .shutdown(at: at + start) }
            if case let .appRelaunch(at) = f { return .appRelaunch(at: at + start) }
            return f
        }
        return SimStream(scooter: FaultInjector.apply(shifted, to: events), phone: [])
    }

    /// Ride 2 at 1 per second (F3) with the phone's own GPS + barometer (F4) on the same clock.
    private func rideTwoWithPhone() throws -> SimStream {
        let text = try Fixtures.text("F3_ride2_merged.csv")
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == "F3" })
        let start = try XCTUnwrap(LogReader.mergedStartTimeOfDayS(text))
        let phone = try PhoneSource.events(locationText: Fixtures.text("F4_ride2_location.csv"),
                                           barometerText: Fixtures.text("F4_ride2_barometer.csv"),
                                           scooterStartTimeOfDayS: start)
        return SimStream(scooter: try sim.events(from: text), phone: phone)
    }

    // MARK: M3 stops

    func test_T23_stopStartsAfter3sBelow3kmh_T24_endsAbove5() {
        var e = riding(until: 10)
        for t in stride(from: 10.5, through: 13.4, by: 0.5) { e.handle(.frame(frame(t, 2.9, amps: 0)), at: t) }
        e.handle(.frame(frame(13.4, 2.9, amps: 0)), at: 13.4)
        XCTAssertTrue(e.ride?.stops.isEmpty ?? false, "2.9 s below 3 km/h is not a stop yet")
        e.handle(.frame(frame(13.5, 2.9, amps: 0)), at: 13.5)
        XCTAssertEqual(e.ride?.stops.count, 1)
        XCTAssertEqual(e.ride?.stops.first?.startT, 10.5, "the stop starts where the speed dropped")
        e.handle(.frame(frame(14, 5.0, amps: 2)), at: 14)
        XCTAssertNil(e.ride?.stops.first?.endT, "5.0 km/h is not above T24")
        e.handle(.frame(frame(14.5, 5.1, amps: 2)), at: 14.5)
        XCTAssertEqual(e.ride?.stops.first?.endT, 14.5)
        XCTAssertEqual(e.ride?.stops.count, 1)
    }

    func test_T23_noStopWhenThePhoneMoved5m() {
        var e = riding(until: 10)
        e.handle(.fix(fix(10.4, northM: 0, kmh: nil)), at: 10.4)
        e.handle(.frame(frame(10.5, 2, amps: 0)), at: 10.5)
        e.handle(.fix(fix(12.0, northM: 3, kmh: nil)), at: 12.0)
        e.handle(.fix(fix(13.4, northM: 6, kmh: nil)), at: 13.4)
        e.handle(.frame(frame(13.5, 2, amps: 0)), at: 13.5)
        XCTAssertTrue(e.ride?.stops.isEmpty ?? false, "rolling slowly, not standing")
    }

    func test_T25_stopsLessThan10sApartMerge_moreDoNot() {
        func run(gap: Double) -> [RideSpan] {
            var e = riding(until: 10)
            for t in stride(from: 10.5, through: 14.0, by: 0.5) { e.handle(.frame(frame(t, 1, amps: 0)), at: t) }
            e.handle(.frame(frame(14.5, 10, amps: 4)), at: 14.5)                     // stop 1: 10.5 → 14.5
            let next = 14.5 + gap
            for t in stride(from: 15.0, to: next, by: 0.5) { e.handle(.frame(frame(t, 10, amps: 4)), at: t) }
            for t in stride(from: next, through: next + 4, by: 0.5) { e.handle(.frame(frame(t, 1, amps: 0)), at: t) }
            e.handle(.frame(frame(next + 5, 10, amps: 4)), at: next + 5)
            return e.ride?.stops ?? []
        }
        XCTAssertEqual(run(gap: 9).count, 1, "9 s apart: one stop")
        XCTAssertEqual(run(gap: 11).count, 2, "11 s apart: two stops")
    }

    // MARK: Pushing (D3, T102)

    func test_T102_pushing30s_isAWalkingStretch_fromWhereItBegan() {
        var e = riding(until: 10)
        var events: [RideEngineEvent] = []
        for t in stride(from: 10.5, through: 39.5, by: 0.5) { events += e.handle(.frame(frame(t, 5, amps: 0.2)), at: t) }
        XCTAssertTrue(e.ride?.walks.isEmpty ?? false, "29 s of pushing")
        events += e.handle(.frame(frame(40.5, 5, amps: 0.2)), at: 40.5)
        XCTAssertEqual(e.ride?.walks.count, 1)
        XCTAssertEqual(e.ride?.walks.first?.startT, 10.5)
        XCTAssertTrue(events.contains(.walkStarted(seq: 1, at: 10.5)))
        XCTAssertEqual(e.ride?.walks.first?.distanceM ?? 0, 5 / 3.6 * 30, accuracy: 3, "30 s at 5 km/h")
        // motor power again ends it (after the 3 s grace)
        for t in stride(from: 41.0, through: 46, by: 0.5) { e.handle(.frame(frame(t, 15, amps: 6)), at: t) }
        XCTAssertEqual(e.ride?.walks.first?.endT, 40.5)
        XCTAssertTrue(e.ride?.motorAfterWalk ?? false)
    }

    func test_T102_motorPowerOrRidingPace_isNotPushing() {
        var e = riding(until: 10)
        for t in stride(from: 10.5, through: 60, by: 0.5) { e.handle(.frame(frame(t, 5, amps: 0.6)), at: t) }
        XCTAssertTrue(e.ride?.walks.isEmpty ?? false, "motor ≥ 0.5 A: riding slowly")
        var f = riding(until: 10)
        for t in stride(from: 10.5, through: 60, by: 0.5) { f.handle(.frame(frame(t, 7.5, amps: 0)), at: t) }
        XCTAssertTrue(f.ride?.walks.isEmpty ?? false, "7.5 km/h is above T102")
    }

    func test_T102_pushingWithoutTheScooter_onGps() {
        var e = riding(until: 10)
        e.handle(.disconnected, at: 10.2)
        var north = 0.0
        for i in 11...60 {
            north += 5 / 3.6
            e.handle(.fix(fix(Double(i), northM: north, kmh: 5)), at: Double(i))
        }
        XCTAssertEqual(e.ride?.walks.count, 1, "walking pace on GPS, scooter gone: pushing (D3)")
        XCTAssertNotNil(e.ride, "walking counts as movement: the ride goes on")
    }

    func test_PUSH_1KM_walkingStretch_batteryRanOut_totals() throws {
        let r = EngineRunner.run(try stream("PUSH-1KM"))
        XCTAssertEqual(r.ends.count, 1)
        let end = try XCTUnwrap(r.ends.first)
        let walk = try XCTUnwrap(end.ride.walks.first)
        XCTAssertEqual(end.ride.walks.count, 1)
        XCTAssertEqual(walk.startT, 299, accuracy: 3, "the motor stopped at ~295 s, walking pace from ~299 s")
        XCTAssertEqual(walk.distanceM, 1_000, accuracy: 120, "1 km walked")
        XCTAssertEqual(end.batteryRanOutPct, 3, "battery ran out at 3%")
        XCTAssertEqual(r.batteryRanOut.first?.pct, 3)
        XCTAssertEqual(end.lowBatteryOffPct, 3)
        XCTAssertEqual(end.sizeClass, .ride)
        XCTAssertEqual(end.distanceM, 3_000, accuracy: 150, "2 km ridden + 1 km walked")
        XCTAssertEqual(end.endT, 1_029, accuracy: 2, "end time = last movement (walking counts)")
        let m = end.metrics(r.samples[end.ride.seq] ?? [])
        XCTAssertEqual(m.walkedM, 1_000, accuracy: 150)
        let avg = (m.avgMovingMps ?? 0) * 3.6
        XCTAssertTrue((20...27).contains(avg), "avg. speed while moving leaves the walk out, got \(avg)")
        XCTAssertLessThan(m.movingS, 330, "walking time is not riding time")
    }

    // MARK: M2 ends

    func test_END_A_SC02_disconnectedWhileStanding_endsAtTheLastMovement() throws {
        let r = EngineRunner.run(try stream("END-A"))
        XCTAssertEqual(r.ends.count, 1)
        let end = try XCTUnwrap(r.ends.first)
        XCTAssertEqual(end.reason, .disconnected)
        XCTAssertEqual(end.decidedAtT, 185, accuracy: 2, "T17: 30 s after the drop, GPS still")
        XCTAssertEqual(end.endT, 135, accuracy: 1.5)
        XCTAssertEqual(end.sizeClass, .shortHop)
        XCTAssertTrue(end.ride.stops.isEmpty, "the standstill at the end is not a stop")
        XCTAssertEqual(end.status, "ended")
    }

    func test_AUTO_OFF_plainDisconnectAfter5min_endsByA() throws {
        let r = EngineRunner.run(try stream("AUTO-OFF"))
        let end = try XCTUnwrap(r.ends.first)
        XCTAssertEqual(r.ends.count, 1)
        XCTAssertEqual(end.reason, .disconnected)
        XCTAssertEqual(end.decidedAtT, 465, accuracy: 2)
        XCTAssertEqual(end.endT, 135, accuracy: 1.5)
    }

    func test_OFF_0x80_A2_endsAtOnce() throws {
        let r = EngineRunner.run(try stream("OFF-0x80"))
        let end = try XCTUnwrap(r.ends.first)
        XCTAssertEqual(end.reason, .scooterOff)
        XCTAssertEqual(end.decidedAtT, 150.5, accuracy: 0.6, "no 30 s wait")
        XCTAssertEqual(end.endT, 135, accuracy: 1.5)
        XCTAssertNil(end.lowBatteryOffPct, "90%: no low-battery label")
    }

    func test_T8_fixture_0x80WhileMoving_endsAtOnce() throws {
        let r = EngineRunner.run(try fixture("F5", "F5_ride2_nrf.csv", faults: [.shutdown(at: 900)]))
        let end = try XCTUnwrap(r.ends.first)
        XCTAssertEqual(r.ends.count, 1)
        XCTAssertEqual(end.reason, .scooterOff)
        XCTAssertLessThan(end.decidedAtT - end.endT, 2, "ends at once")
    }

    func test_STANDSTILL_C_after10min() throws {
        let r = EngineRunner.run(try stream("STANDSTILL-10"))
        let end = try XCTUnwrap(r.ends.first)
        XCTAssertEqual(end.reason, .standstill)
        XCTAssertEqual(end.decidedAtT, 135 + T.t20EndStandstillS, accuracy: 2)
        XCTAssertEqual(end.endT, 135, accuracy: 1.5)
    }

    func test_A_justInsideAndOutside_andNoGpsWaits2min() {
        // GPS still: ends at 30 s, not at 29
        var e = riding(until: 10)
        e.handle(.frame(frame(10.5, 0, amps: 0)), at: 10.5)
        e.handle(.disconnected, at: 11)
        for i in 0...29 { e.handle(.fix(fix(11 + Double(i), kmh: 0)), at: 11 + Double(i)) }
        XCTAssertNotNil(e.ride, "29 s")
        let out = e.handle(.fix(fix(41, kmh: 0)), at: 41)
        guard case let .rideEnded(end)? = out.last else { return XCTFail("expected an end at 30 s, got \(out)") }
        XCTAssertEqual(end.reason, .disconnected)
        XCTAssertEqual(end.endT, 10, accuracy: 0.01, "last movement")

        // no good fix at all: T18 2 min
        var f = riding(until: 10)
        f.handle(.disconnected, at: 11)
        for i in 12...130 { f.handle(.tick, at: Double(i)) }
        XCTAssertNotNil(f.ride, "119 s without the scooter and without GPS")
        let late = f.handle(.tick, at: 131)
        XCTAssertEqual(late.count, 1)
        if case let .rideEnded(end)? = late.first { XCTAssertEqual(end.reason, .disconnected) } else { XCTFail("\(late)") }

        // moving on GPS: the ride goes on in phone mode
        var g = riding(until: 10)
        g.handle(.disconnected, at: 11)
        var north = 0.0
        for i in 12...200 {
            north += 20 / 3.6
            g.handle(.fix(fix(Double(i), northM: north, kmh: 20)), at: Double(i))
        }
        XCTAssertNotNil(g.ride)
    }

    func test_A_oneSecondBlip_doesNothing() {
        var e = riding(until: 10)
        e.handle(.disconnected, at: 10.2)
        e.handle(.connected, at: 11)
        for t in stride(from: 11.0, through: 60, by: 0.5) { e.handle(.frame(frame(t, 20, amps: 8)), at: t) }
        XCTAssertEqual(e.phase, .riding)
        XCTAssertEqual(e.ride?.seq, 1)
    }

    func test_lowBatteryOff_label_andStartingCancelledBy0x80() {
        var e = riding(until: 10)
        e.handle(.frame(frame(10.5, 0, amps: 0, batt: 4, off: true)), at: 10.5)
        let out = e.handle(.disconnected, at: 11)
        guard case let .rideEnded(end)? = out.last else { return XCTFail("\(out)") }
        XCTAssertEqual(end.reason, .scooterOff)
        XCTAssertEqual(end.lowBatteryOffPct, 4, "ended: scooter switched off at 4%")

        var f = riding(until: 10)
        f.handle(.frame(frame(10.5, 0, amps: 0, batt: 6, off: true)), at: 10.5)
        if case let .rideEnded(end)? = f.handle(.disconnected, at: 11).last { XCTAssertNil(end.lowBatteryOffPct, "6% is above T80's 5%") }

        var g = RideEngine()
        g.handle(.connected, at: 0)
        g.handle(.frame(frame(1, 4)), at: 1)
        g.handle(.frame(frame(2, 0, off: true)), at: 2)
        XCTAssertEqual(g.handle(.disconnected, at: 3), [.rideCancelled(seq: 1, at: 3, reason: .scooterOff)],
                       "an unconfirmed start is dropped when the scooter switches off")
    }

    // MARK: Same ride (T21) and M36

    func test_SAME_RIDE_offered_andYesJoinsTheGroup() throws {
        let r = EngineRunner.run(try stream("SAME-RIDE"), answerSameRide: true)
        XCTAssertEqual(r.ends.count, 2)
        XCTAssertEqual(r.ends.first?.reason, .scooterOff)
        XCTAssertEqual(r.sameRideOffers.count, 1)
        XCTAssertEqual(r.sameRideOffers.first?.seq, 2)
        XCTAssertEqual(r.sameRideOffers.first?.previousSeq, 1)
        XCTAssertTrue(r.events.contains { $0.event == .rideMerged(seq: 2, intoSeq: 1) })
        XCTAssertEqual(r.ends.last?.ride.mergedIntoSeq, 1)
        let pieces = r.ends.map(\.distanceM)
        XCTAssertEqual(RideSizeClass.of(groupDistancesM: pieces), .shortHop, "M36 re-checked on the joined pieces")

        let no = EngineRunner.run(try stream("SAME-RIDE"), answerSameRide: false)
        XCTAssertNil(no.ends.last?.ride.mergedIntoSeq)
    }

    func test_sameRide_notAfterAHeldEnd_notAfter10min() {
        // held end → no offer
        var e = riding(until: 10)
        e.handle(.endHeld, at: 11)
        e.handle(.frame(frame(12, 0)), at: 12)
        var out: [RideEngineEvent] = []
        for t in stride(from: 13.0, through: 16, by: 0.5) { out += e.handle(.frame(frame(t, 10, amps: 5)), at: t) }
        XCTAssertFalse(out.contains { if case .sameRideOffered = $0 { return true }; return false })

        func offerAfter(_ gap: Double) -> Bool {
            var f = riding(until: 10)
            f.handle(.frame(frame(10.5, 0, amps: 0, off: true)), at: 10.5)
            f.handle(.disconnected, at: 11)                                   // A2, end at the last movement (10)
            let back = 10 + gap
            f.handle(.connected, at: back - 1)
            f.handle(.frame(frame(back - 0.5, 0)), at: back - 0.5)
            var events: [RideEngineEvent] = []
            for t in stride(from: back, through: back + 3, by: 0.5) { events += f.handle(.frame(frame(t, 10, amps: 5)), at: t) }
            return events.contains { if case .sameRideOffered = $0 { return true }; return false }
        }
        XCTAssertTrue(offerAfter(599), "within 10 min (no GPS: time only)")
        XCTAssertFalse(offerAfter(601), "after 10 min")
    }

    func test_M36_sizeClasses_atTheEdges() {
        XCTAssertEqual(RideSizeClass.of(distanceM: 499.9), .discarded)
        XCTAssertEqual(RideSizeClass.of(distanceM: (632.1 - 631.6) * 1000), .shortHop, "no float edge at 0.5 km")
        XCTAssertEqual(RideSizeClass.of(distanceM: 1_999.9), .shortHop)
        XCTAssertEqual(RideSizeClass.of(distanceM: 2_000), .ride)
        XCTAssertEqual(RideSizeClass.of(groupDistancesM: [300, 300]), .shortHop)
    }

    // MARK: Recovery (SC-14)

    func test_SC14_relaunchMidRide_resumes_sameRide() throws {
        let s = try rideTwoWithPhone()
        let clean = EngineRunner.run(s)
        let relaunched = EngineRunner.run(s, relaunchAt: 600, relaunchGapS: 3)
        XCTAssertEqual(relaunched.recoveries, [.resume])
        XCTAssertEqual(relaunched.started.count, clean.started.count, "no second ride")
        let a = try XCTUnwrap(clean.ends.first), b = try XCTUnwrap(relaunched.ends.first)
        XCTAssertEqual(b.ride.seq, a.ride.seq)
        XCTAssertEqual(b.reason, a.reason)
        XCTAssertEqual(b.distanceM, a.distanceM, accuracy: 100)
        XCTAssertEqual(b.ride.startT, a.ride.startT)
    }

    func test_SC14_killedLong_isRecovered_atItsLastSample() throws {
        let r = EngineRunner.run(try rideTwoWithPhone(), relaunchAt: 600, relaunchGapS: 300)
        guard case let .endRecovered(end)? = r.recoveries.first else { return XCTFail("\(r.recoveries)") }
        XCTAssertEqual(end.reason, .recovered)
        XCTAssertEqual(end.status, "recovered")
        XCTAssertLessThanOrEqual(600 - end.endT, 5, "≤ 5 s lost")
        XCTAssertEqual(r.ends.first, end)
    }

    func test_recovery_decisions() throws {
        XCTAssertEqual(RideRecovery.decide(snapshot: RideEngine(), lastDataT: nil, now: 100), .nothingOpen)
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, 4)), at: 1)                       // stage 1, not confirmed
        let restored = try JSONDecoder().decode(RideEngine.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(RideRecovery.decide(snapshot: restored, lastDataT: 1, now: 100), .resume)
        XCTAssertEqual(RideRecovery.decide(snapshot: restored, lastDataT: 1, now: 122), .discard(seq: 1, at: 1),
                       "never confirmed: deleted like a silent cancel")
    }

    // MARK: Hand-off to the metrics + golden values through the whole engine

    func test_metricsInput_movingFlag_stopRows() throws {
        let r = EngineRunner.run(try stream("PUSH-1KM"))
        let end = try XCTUnwrap(r.ends.first)
        let input = end.metricsInput(r.samples[end.ride.seq] ?? [])
        let walk = try XCTUnwrap(input.walks.first)
        XCTAssertFalse(input.samples.contains { $0.t > walk.startT + 1 && $0.t < (walk.endT ?? 0) - 1 && $0.moving == true },
                       "no sample in the walking stretch counts as moving")
        XCTAssertTrue(input.samples.contains { $0.moving == true })
        XCTAssertFalse(input.samples.contains { $0.t > end.endT - end.ride.startT + 0.1 && $0.moving == true },
                       "nothing moves after the end")
        XCTAssertTrue(input.samples.allSatisfy { $0.moving != nil }, "the engine sets every flag")
    }

    func test_golden_ridesThroughTheEngine_endedByTheScooterSwitchingOff() throws {
        for (id, file, wh, km) in [("F2", "F2_ride1_nrf.csv", 437.0, 16.3), ("F5", "F5_ride2_nrf.csv", 322.0, 13.7)] {
            let r = EngineRunner.run(try fixture(id, file))
            XCTAssertEqual(r.ends.count, 1, id)
            let end = try XCTUnwrap(r.ends.first)
            XCTAssertEqual(end.reason, .scooterOff, "\(id): 0x80 at the end of the ride")
            XCTAssertEqual(end.sizeClass, .ride, id)
            XCTAssertEqual(end.distanceM / 1000, km, accuracy: 0.15, id)
            let m = end.metrics(r.samples[end.ride.seq] ?? [])
            XCTAssertEqual(m.energyWhRaw, wh, accuracy: wh * 0.03, id)
            XCTAssertEqual(m.distanceKm, km, accuracy: 0.15, id)
            XCTAssertEqual(m.stops, end.ride.stops.count, id)
            XCTAssertGreaterThan(m.stops, 0, "\(id) has stops")
        }
    }

    func test_golden_ride2_withPhoneGps_throughTheEngine() throws {
        let r = EngineRunner.run(try rideTwoWithPhone())
        let end = try XCTUnwrap(r.ends.first)
        XCTAssertEqual(r.started.count, 1)
        let m = end.metrics(r.samples[end.ride.seq] ?? [])
        XCTAssertEqual(m.energyWhRaw, 322, accuracy: 322 * 0.03)
        XCTAssertEqual(m.distanceKm, 13.7, accuracy: 0.15)
        XCTAssertTrue(m.hasGps)
        XCTAssertGreaterThan(end.ride.stops.count, 0)
    }

    func test_F1_twoShortRides_firstEndedByThe0x80() throws {
        let r = EngineRunner.run(try fixture("F1", "F1_p2lab_2oct.csv"))
        XCTAssertGreaterThanOrEqual(r.ends.count, 2)
        XCTAssertEqual(r.ends.first?.reason, .scooterOff, "0x80 at 08:24:34, then silence")
        XCTAssertEqual(r.ends.first?.sizeClass, .shortHop)
    }
}
