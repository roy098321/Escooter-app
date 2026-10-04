import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// M1-03: ride start (CALC_SPEC M1): stage 1 at T10, stage 2 by T11 / T12 / T13, silent cancel by T14 /
/// T15 / Not riding, manual Start ride skips stage 2, walking trim (T16), the three autostart traps and
/// the golden rides through the engine.
final class RideEngineStartTests: XCTestCase {
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

    private func fix(_ t: Double, northM: Double = 0, kmh: Double? = 0, acc: Double = 5) -> PhoneFix {
        PhoneFix(t: t, lat: 10 + northM / 111_320, lon: -30, hAccM: acc, speedMps: kmh.map { $0 / 3.6 } ?? -1)
    }

    /// Connected engine with the wheel at `kmh` from t = 1 (stage 1 when > T10).
    private func started(kmh: Double = 10) -> (RideEngine, [RideEngineEvent]) {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(0.5, 0)), at: 0.5)
        let out = e.handle(.frame(frame(1, kmh)), at: 1)
        return (e, out)
    }

    private func stream(_ id: String) throws -> SimStream {
        try XCTUnwrap(SyntheticScenario.all.first { $0.id == id }).build()
    }

    private func fixtureStream(_ id: String, file: String) throws -> SimStream {
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == id })
        return SimStream(scooter: try sim.events(from: Fixtures.text(file)), phone: [])
    }

    // MARK: Stage 1 (T10)

    func test_T10_stage1_justInsideAndOutside() {
        var e = RideEngine()
        XCTAssertEqual(e.phase, .idle)
        e.handle(.connected, at: 0)
        XCTAssertEqual(e.phase, .ready)
        XCTAssertTrue(e.handle(.frame(frame(1, 2.0)), at: 1).isEmpty, "2.0 km/h is not above T10")
        XCTAssertEqual(e.phase, .ready)
        let out = e.handle(.frame(frame(2, 2.05)), at: 2)
        XCTAssertEqual(out, [.rideStarted(seq: 1, at: 2, manual: false)])
        XCTAssertEqual(e.phase, .starting)
        XCTAssertTrue(e.rideActive)
        XCTAssertTrue(e.liveInput(at: 2).starting, "the live view shows the starting… dot")
    }

    func test_noStartWithoutTheScooter_andNotWhileShuttingDown() {
        var e = RideEngine()
        XCTAssertTrue(e.handle(.startPressed, at: 0).isEmpty, "Start ride needs the scooter (v1 rule)")
        e.handle(.connected, at: 1)
        XCTAssertTrue(e.handle(.frame(frame(2, 5, off: true)), at: 2).isEmpty, "0x80: the scooter is switching off")
        XCTAssertEqual(e.phase, .ready)
    }

    // MARK: Stage 2 (T11, T12, T13)

    func test_T11_current_1s_justInsideAndOutside() {
        var (e, _) = started()
        e.handle(.frame(frame(2.0, 10, amps: 0.6)), at: 2.0)
        XCTAssertTrue(e.handle(.frame(frame(2.9, 10, amps: 0.6)), at: 2.9).isEmpty, "0.9 s is not enough")
        let out = e.handle(.frame(frame(3.0, 10, amps: 0.6)), at: 3.0)
        XCTAssertEqual(out, [.rideConfirmed(seq: 1, at: 3.0, by: .current)])
        XCTAssertEqual(e.phase, .riding)

        var (f, _) = started()
        for t in stride(from: 2.0, through: 6.0, by: 0.5) { f.handle(.frame(frame(t, 10, amps: 0.5)), at: t) }
        XCTAssertEqual(f.phase, .starting, "0.5 A is not above T11")
    }

    func test_T12_gpsSpeed_3s_justInsideAndOutside() {
        var (e, _) = started(kmh: 9)
        for t in stride(from: 1.0, through: 3.9, by: 1.0) {
            e.handle(.frame(frame(t + 0.2, 9)), at: t + 0.2)
            e.handle(.fix(fix(t, kmh: 8.1)), at: t)
        }
        XCTAssertEqual(e.phase, .starting, "8.1 km/h for 2.9 s")
        let out = e.handle(.fix(fix(4.0, kmh: 8.1)), at: 4.0)
        XCTAssertEqual(out, [.rideConfirmed(seq: 1, at: 4.0, by: .gpsSpeed)])

        var (f, _) = started(kmh: 9)
        for t in stride(from: 1.0, through: 9.0, by: 1.0) {
            f.handle(.frame(frame(t + 0.2, 9)), at: t + 0.2)
            f.handle(.fix(fix(t, kmh: 8.0)), at: t)
        }
        XCTAssertEqual(f.phase, .starting, "8.0 km/h is not above T12")
    }

    func test_T13_gpsDistance_whileTheWheelMoves() {
        var (e, _) = started(kmh: 6)
        e.handle(.fix(fix(1.1, northM: 0, kmh: nil)), at: 1.1)
        e.handle(.frame(frame(2, 6)), at: 2)
        XCTAssertTrue(e.handle(.fix(fix(2.1, northM: 49, kmh: nil)), at: 2.1).isEmpty, "49 m")
        let out = e.handle(.fix(fix(2.5, northM: 50.5, kmh: nil)), at: 2.5)
        XCTAssertEqual(out, [.rideConfirmed(seq: 1, at: 2.5, by: .gpsDistance)])

        // the phone moves 60 m but the wheel stands (scooter carried / in a car): no confirm by distance
        var (f, _) = started(kmh: 6)
        f.handle(.fix(fix(1.1, kmh: nil)), at: 1.1)
        f.handle(.frame(frame(2, 0)), at: 2)
        f.handle(.fix(fix(2.5, northM: 60, kmh: nil)), at: 2.5)
        XCTAssertEqual(f.phase, .starting)
    }

    // MARK: Silent cancel (T14, T15, Not riding)

    func test_T14_gpsStillWhileTheWheelSpins_cancelsAt20s() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        var events: [(Double, RideEngineEvent)] = []
        for i in 0...40 {
            let t = Double(i)
            e.handle(.fix(fix(t, kmh: 0)), at: t)
            for out in e.handle(.frame(frame(t + 0.3, t < 5 ? 0 : 15, amps: 0.3)), at: t + 0.3) { events.append((t + 0.3, out)) }
        }
        let start = events.first { if case .rideStarted = $0.1 { return true }; return false }
        let cancel = events.first { if case .rideCancelled = $0.1 { return true }; return false }
        XCTAssertEqual(start?.0, 5.3)
        XCTAssertEqual(cancel?.1, .rideCancelled(seq: 1, at: 25.3, reason: .gpsStill), "T14: 20 s after stage 1")
        XCTAssertNil(e.ride)
        XCTAssertEqual(e.phase, .ready)
    }

    func test_T14_noCancelWithoutAGoodFix() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        for i in 0...60 {
            let t = Double(i)
            e.handle(.fix(fix(t, kmh: 0, acc: 35)), at: t)          // poor fix (> T28)
            e.handle(.frame(frame(t + 0.3, t < 5 ? 0 : 15, amps: 0.3)), at: t + 0.3)
        }
        XCTAssertEqual(e.phase, .starting, "no good fix: only T15 can cancel")
    }

    func test_T15_unconfirmed_justInsideAndOutside() {
        var (e, _) = started(kmh: 3)
        var cancelledAt: Double?
        for i in 2...125 {
            let t = Double(i)
            for out in e.handle(.frame(frame(t, 3)), at: t) {
                if case let .rideCancelled(_, at, reason) = out, reason == .unconfirmed { cancelledAt = at }
            }
            if t == 120 { XCTAssertNotNil(e.ride, "119 s after stage 1 the ride still waits") }
        }
        XCTAssertEqual(cancelledAt, 121, "stage 1 at 1 s + T15 120 s")
    }

    func test_notRiding_cancelsSilently() {
        var (e, _) = started()
        let out = e.handle(.notRidingPressed, at: 5)
        XCTAssertEqual(out, [.rideCancelled(seq: 1, at: 5, reason: .notRiding)])
        XCTAssertNil(e.ride)
        XCTAssertFalse(e.rideActive)
    }

    // MARK: Manual start, hold to end, re-arm

    func test_manualStart_skipsStage2_andHoldEnds() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(0.5, 0)), at: 0.5)
        let out = e.handle(.startPressed, at: 1)
        XCTAssertEqual(out, [.rideStarted(seq: 1, at: 1, manual: true), .rideConfirmed(seq: 1, at: 1, by: .manual)])
        XCTAssertEqual(e.phase, .riding)
        XCTAssertFalse(e.liveInput(at: 1).starting, "no starting… dot after Start ride")
        for t in stride(from: 2.0, through: 20, by: 1) { e.handle(.frame(frame(t, 0)), at: t) }
        let end = e.handle(.endHeld, at: 21)
        guard case let .rideEnded(r)? = end.first else { return XCTFail("held end expected, got \(end)") }
        XCTAssertEqual(r.reason, .held)
        XCTAssertEqual(r.sizeClass, .discarded, "l5: a piece < 0.5 km is discarded")
        XCTAssertEqual(e.phase, .ready)
    }

    func test_heldEndWhileRolling_waitsForTheWheelToStopBeforeTheNextStart() {
        var (e, _) = started(kmh: 10)
        e.handle(.endHeld, at: 3)
        XCTAssertTrue(e.handle(.frame(frame(4, 10)), at: 4).isEmpty, "still rolling: no new ride")
        e.handle(.frame(frame(5, 1)), at: 5)
        XCTAssertEqual(e.handle(.frame(frame(6, 4)), at: 6), [.rideStarted(seq: 2, at: 6, manual: false)])
    }

    // MARK: Walking trim (T16)

    func test_T16_walkingTrim_startsAtRidingPaceOrMotorPower() {
        var (e, _) = started(kmh: 5)
        e.handle(.frame(frame(2, 5)), at: 2)
        XCTAssertNil(e.ride?.trimStartT, "walking pace, no current")
        e.handle(.frame(frame(3, 6.9, amps: 0.4)), at: 3)
        XCTAssertNil(e.ride?.trimStartT)
        e.handle(.frame(frame(4, 6.9, amps: 0.5, odo: 100.1)), at: 4)
        XCTAssertEqual(e.ride?.trimStartT, 4, "motor power from here")
        XCTAssertEqual(e.ride?.odoTrimKm, 100.1)

        var (f, _) = started(kmh: 5)
        f.handle(.frame(frame(2, 7.0)), at: 2)
        XCTAssertEqual(f.ride?.trimStartT, 2, "riding pace (≥ 7 km/h)")
    }

    // MARK: The three autostart traps through the fake scooter (TRAP-*, SC-16)

    func test_TRAP_WALK_SC16_isCancelledOrTrimmedAway() throws {
        let r = EngineRunner.run(try stream("TRAP-WALK"), tailS: 30)
        XCTAssertEqual(r.started.count, 1)
        if r.cancelled.isEmpty {
            let ride = try XCTUnwrap(r.engine.ride ?? r.ends.first?.ride)
            XCTAssertNil(ride.trimStartT, "the whole piece is walking: it is trimmed away")
            XCTAssertEqual(ride.distanceAfterTrimM, 0)
        }
    }

    func test_TRAP_SPIN_isCancelledWithin20s() throws {
        let r = EngineRunner.run(try stream("TRAP-SPIN"), tailS: 30)
        let start = try XCTUnwrap(r.started.first)
        let cancel = try XCTUnwrap(r.cancelled.first)
        XCTAssertEqual(cancel.reason, .gpsStill)
        XCTAssertLessThanOrEqual(cancel.at - start.at, T.t14CancelGpsStillS + 1, "t2: ≤ 20 s with a good fix")
        XCTAssertTrue(r.confirmed.isEmpty)
        XCTAssertTrue(r.ends.isEmpty, "no ride row left")
    }

    func test_TRAP_KICK_confirmsByCurrent_andRecordsTheSignal() throws {
        let r = EngineRunner.run(try stream("TRAP-KICK"), tailS: 30)
        XCTAssertTrue(r.cancelled.isEmpty)
        let c = try XCTUnwrap(r.confirmed.first)
        XCTAssertEqual(c.by, .current)
        XCTAssertLessThan(c.at, 8, "kick at ~3 s, motor from 5 s")
        let ride = try XCTUnwrap(r.engine.ride ?? r.ends.first?.ride)
        XCTAssertEqual(ride.trimStartT ?? -1, 5, accuracy: 0.6, "the kick (no motor yet) is trimmed")
    }

    // MARK: Recorded rides through the engine

    /// F1 golden: the scooter reports speeds down to 0.14 km/h while standing; no ride starts from them.
    func test_F1_noStartFromTinySpeeds_firstRideAtTheRealRoll() throws {
        let r = EngineRunner.run(try fixtureStream("F1", file: "F1_p2lab_2oct.csv"), tailS: 30)
        let first = try XCTUnwrap(r.started.first)
        XCTAssertGreaterThan(first.at, 600, "nothing during the 10 min standing / modes / brake part")
        XCTAssertEqual(r.confirmed.first?.by, .current)
        XCTAssertTrue(r.cancelled.isEmpty)
    }

    /// Golden values hold through the engine: ride 1 = 437 Wh / 16.3 km, ride 2 = 322 Wh / 13.7 km.
    func test_golden_bothRides_throughTheEngine() throws {
        for (id, file, wh, km) in [("F2", "F2_ride1_nrf.csv", 437.0, 16.3), ("F5", "F5_ride2_nrf.csv", 322.0, 13.7)] {
            let s = try fixtureStream(id, file: file)
            let endT = (s.scooter.last?.t ?? 0) + 5
            let r = EngineRunner.run(s, presses: [EngineRunner.Press(t: endT, .endHeld)], tailS: 10)
            XCTAssertEqual(r.started.count, 1, id)
            XCTAssertEqual(r.confirmed.first?.by, .current, id)
            XCTAssertTrue(r.cancelled.isEmpty, id)
            let ride = try XCTUnwrap(r.started.first)
            let m = RideMetricsCalculator.compute(r.samples[ride.seq] ?? [])
            XCTAssertEqual(m.energyWhRaw, wh, accuracy: wh * 0.03, id)
            XCTAssertEqual(m.distanceKm, km, accuracy: 0.15, id)
        }
    }

    // MARK: State survives JSON (recovery, M1-04)

    func test_engineState_roundTripsThroughJSON() throws {
        var (e, _) = started()
        e.handle(.fix(fix(1.5, kmh: 9)), at: 1.5)
        e.handle(.frame(frame(2, 12, amps: 4)), at: 2)
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(RideEngine.self, from: data)
        XCTAssertEqual(back, e)
    }
}
