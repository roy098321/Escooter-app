import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// M1-02: the fake scooter also replays the phone's GPS and barometer on the same virtual clock,
/// the phone fault markers are real, and the new synthetic scenarios produce their event streams.
final class PhoneReplayTests: XCTestCase {
    // MARK: Helpers

    private func f3Text() throws -> String { try Fixtures.text("F3_ride2_merged.csv") }

    /// F3 (scooter, 1 per second) + F4 (the phone's own GPS and barometer) on one clock.
    private func rideTwoStream() throws -> SimStream {
        let text = try f3Text()
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == "F3" })
        let start = try XCTUnwrap(LogReader.mergedStartTimeOfDayS(text))
        let phone = try PhoneSource.events(locationText: Fixtures.text("F4_ride2_location.csv"),
                                           barometerText: Fixtures.text("F4_ride2_barometer.csv"),
                                           scooterStartTimeOfDayS: start)
        return SimStream(scooter: try sim.events(from: text), phone: phone)
    }

    private func metres(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dLat = (a.0 - b.0) * 111_320
        let dLon = (a.1 - b.1) * 111_320 * cos(a.0 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    private func frames(_ events: [TimedScooterEvent]) -> [ScooterFrame] {
        var assembler = FrameAssembler()
        return events.compactMap { e in e.bytes.flatMap { assembler.ingest($0, at: e.t) } }
    }

    // MARK: F3 / F4 replay

    /// F4's phone track, put on the scooter clock, lines up with the F3 samples second by second.
    func test_F4_phoneTrackLinesUpWithF3() throws {
        let samples = try LogReader.mergedSamples(f3Text())
        let phone = try rideTwoStream().phone
        var distances: [Double] = []
        for event in phone {
            guard let fix = event.fix, fix.t >= 0, fix.t <= 1_809 else { continue }
            let s = samples[Int(fix.t.rounded())]
            distances.append(metres((fix.lat, fix.lon), (s.lat ?? 0, s.lon ?? 0)))
        }
        XCTAssertGreaterThan(distances.count, 1_700, "about one fix a second over 30 min")
        XCTAssertLessThan(distances.reduce(0, +) / Double(distances.count), 5, "mean distance to the F3 position, m")

        var baroDiffs: [Double] = []
        for event in phone {
            guard let b = event.baro, b.t >= 0, b.t <= 1_809, let rel = samples[Int(b.t.rounded())].elevBaroM else { continue }
            baroDiffs.append(abs(b.relativeAltitudeM - rel))
        }
        XCTAssertGreaterThan(baroDiffs.count, 1_000)
        XCTAssertLessThan(baroDiffs.reduce(0, +) / Double(baroDiffs.count), 0.5, "barometer vs F3 elevation, m")
    }

    /// Both streams play on ONE clock: a 50× run delivers every scooter and phone event, in time order.
    func test_replay_bothStreamsOnOneClock() throws {
        let stream = try rideTwoStream()
        let session = ReplaySession(stream: stream, speed: 50)
        var scooterSeen = 0, phoneSeen = 0
        var lastPhone = -Double.infinity
        var guardCount = 0
        while !session.isFinished, guardCount < 10_000 {
            let due = session.advanceAll(realSeconds: 1)
            scooterSeen += due.scooter.count
            for e in due.phone {
                XCTAssertGreaterThanOrEqual(e.t, lastPhone)
                XCTAssertLessThanOrEqual(e.t, session.clock.now + 1e-9, "never delivered before its time")
                lastPhone = e.t
            }
            phoneSeen += due.phone.count
            guardCount += 1
        }
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(scooterSeen, stream.scooter.count)
        XCTAssertEqual(phoneSeen, stream.phone.count)
        XCTAssertGreaterThan(stream.phone.filter { $0.fix != nil }.count, 1_800)
        XCTAssertGreaterThan(stream.phone.filter { $0.baro != nil }.count, 1_500)
    }

    /// Golden values still hold through the new session type (437 Wh / 16.3 km and 322 Wh / 13.7 km).
    func test_golden_valuesStillHold_withPhoneReplay() throws {
        let stream = try rideTwoStream()
        var p = ScooterPipeline()
        let all = ReplaySession(stream: stream, speed: 50).runToEndAll()
        p.handle(Array(all.scooter))
        XCTAssertEqual(p.totals.energyWhRaw, 322, accuracy: 322 * 0.03)
        XCTAssertEqual(p.totals.distanceKm, 13.7, accuracy: 0.05)
        XCTAssertFalse(all.phone.isEmpty)

        let ride1 = try XCTUnwrap(SimFixture.all.first { $0.id == "F2" })
        var q = ScooterPipeline()
        q.handle(Array(ReplaySession(events: try ride1.events(from: Fixtures.text("F2_ride1_nrf.csv")), speed: 50).runToEnd()))
        XCTAssertEqual(q.totals.energyWhRaw, 437, accuracy: 437 * 0.03)
        XCTAssertEqual(q.totals.distanceKm, 16.3, accuracy: 0.05)
    }

    /// The re-encoded F3 route as the phone sees it (one fix a second) matches the F4 track.
    func test_F3_asPhoneSource_oneFixAndOneReadingPerSecond() throws {
        let samples = try LogReader.mergedSamples(f3Text())
        let phone = PhoneSource.events(fromMerged: samples)
        XCTAssertEqual(phone.filter { $0.fix != nil }.count, samples.count)
        let fix = try XCTUnwrap(phone.compactMap(\.fix).first { $0.t == 600 })
        XCTAssertEqual(fix.speedMps * 3.6, samples[600].gpsSpeedKmh ?? -1, accuracy: 0.01)
        XCTAssertTrue(fix.isGood)
    }

    // MARK: Phone fault markers made real

    func test_SC07_gpsLoss_removesFixesInTheWindow() throws {
        let stream = try rideTwoStream()
        let faulted = stream.applying([.gpsLoss(from: 600, to: 720)])
        XCTAssertFalse(faulted.phone.contains { $0.fix != nil && $0.t >= 600 && $0.t <= 720 })
        XCTAssertTrue(faulted.phone.contains { $0.fix != nil && $0.t > 721 }, "GPS comes back")
        XCTAssertTrue(faulted.phone.contains { $0.baro != nil && $0.t >= 600 && $0.t <= 720 }, "the barometer keeps going")
        XCTAssertEqual(faulted.scooter.count, stream.scooter.count, "the scooter stream is untouched")
    }

    func test_barometerStop_andPhoneMarkers() throws {
        let stream = try rideTwoStream()
        let faulted = stream.applying([.barometerStop(at: 900), .offline(from: 100, to: 200),
                                       .phoneBattery(at: 300, pct: 19), .appRelaunch(at: 600), .serviceDown(name: "weather")])
        XCTAssertFalse(faulted.phone.contains { $0.baro != nil && $0.t >= 900 })
        XCTAssertTrue(faulted.phone.contains { $0.t == 100 && $0.event == .offline(true) })
        XCTAssertTrue(faulted.phone.contains { $0.t == 200 && $0.event == .offline(false) })
        XCTAssertTrue(faulted.phone.contains { $0.t == 300 && $0.event == .phoneBattery(pct: 19) })
        XCTAssertTrue(faulted.phone.contains { $0.t == 600 && $0.event == .appRelaunch })
        XCTAssertTrue(faulted.phone.contains { $0.event == .serviceDown("weather") })
        XCTAssertEqual(faulted.phone.map(\.t), faulted.phone.map(\.t).sorted(), "still in time order")
    }

    func test_streamFaults_leavePhoneUntouched() throws {
        let stream = try rideTwoStream()
        let faulted = stream.applying([.disconnect(at: 724, durationS: 60)])
        XCTAssertEqual(faulted.phone, stream.phone)
        XCTAssertFalse(faulted.scooter.contains { $0.t > 724 && $0.t < 784 && $0.bytes != nil })
    }

    // MARK: Synthetic scenarios

    private func scenario(_ id: String) throws -> SimStream {
        try XCTUnwrap(SyntheticScenario.all.first { $0.id == id }).build()
    }

    func test_syntheticCatalog_hasTheFiveScenarios() {
        XCTAssertEqual(SyntheticScenario.all.map(\.id), ["SPD-46", "SPD-46-GPS", "TRAP-WALK", "TRAP-SPIN", "TRAP-KICK"])
    }

    /// SPD-46: the scooter goes 40 → 46 → 44 → 46 → 42 km/h; the phone's GPS says the same.
    func test_SPD46_rampsThroughTheWarningThresholds() throws {
        let stream = try scenario("SPD-46")
        let speeds = frames(stream.scooter).compactMap(\.speedKmh)
        XCTAssertEqual(speeds.max() ?? 0, 46, accuracy: 0.1)
        let pipeline = { () -> ScooterPipeline in var p = ScooterPipeline(); p.handle(stream.scooter); return p }()
        XCTAssertEqual(pipeline.plausibility.ignoredReadings, 0, "the ramp is smooth enough for G1b")
        // crossings of 45 going up and of 43 going down, in order: up, (44 is between), up again, down
        let at = { (t: Double) in frames(stream.scooter).last { $0.t <= t }?.speedKmh ?? -1 }
        XCTAssertEqual(at(30), 40, accuracy: 0.6)
        XCTAssertEqual(at(36), 46, accuracy: 0.6)
        XCTAssertEqual(at(40), 44, accuracy: 0.6)
        XCTAssertEqual(at(44), 46, accuracy: 0.6)
        XCTAssertEqual(at(52), 42, accuracy: 0.6)
        let gps = stream.phone.compactMap(\.fix).map { $0.speedMps * 3.6 }
        XCTAssertEqual(gps.max() ?? 0, 46, accuracy: 0.1)
    }

    /// SPD-46-GPS: the scooter drops while GPS reads 46; the phone keeps reporting 46.
    func test_SPD46GPS_scooterDropsWhileGpsReads46() throws {
        let stream = try scenario("SPD-46-GPS")
        XCTAssertFalse(stream.scooter.contains { $0.t > 70 && $0.t < 110 && $0.bytes != nil })
        XCTAssertTrue(stream.scooter.contains { $0.t == 70 && $0.event == .disconnected })
        XCTAssertTrue(stream.scooter.contains { $0.t == 110 && $0.event == .connected })
        let inGap = stream.phone.compactMap(\.fix).filter { $0.t > 75 && $0.t < 105 }
        XCTAssertGreaterThan(inGap.count, 25)
        for fix in inGap { XCTAssertEqual(fix.speedMps * 3.6, 46, accuracy: 0.1) }
    }

    /// TRAP-WALK: 5 km/h on the wheel, no motor current, GPS walking.
    func test_TRAPWALK_walkingTheScooter() throws {
        let stream = try scenario("TRAP-WALK")
        let moving = frames(stream.scooter).filter { $0.t > 10 }
        XCTAssertFalse(moving.isEmpty)
        for f in moving {
            XCTAssertEqual(f.speedKmh ?? -1, 5, accuracy: 0.1)
            if let a = f.currentA { XCTAssertLessThan(a, T.t11ConfirmCurrentA) }
        }
        for fix in stream.phone.compactMap(\.fix).dropFirst() { XCTAssertEqual(fix.speedMps * 3.6, 5, accuracy: 0.05) }
        XCTAssertLessThan(5, T.t16WalkingKmh)
    }

    /// TRAP-SPIN: wheel at 15 km/h, motor barely loaded, GPS never moves.
    func test_TRAPSPIN_wheelSpinningOnTheStand() throws {
        let stream = try scenario("TRAP-SPIN")
        let spinning = frames(stream.scooter).filter { $0.t > 8 }
        for f in spinning {
            XCTAssertEqual(f.speedKmh ?? -1, 15, accuracy: 0.1)
            if let a = f.currentA { XCTAssertLessThan(a, T.t11ConfirmCurrentA) }
        }
        let fixes = stream.phone.compactMap(\.fix)
        XCTAssertTrue(fixes.allSatisfy { $0.speedMps == 0 })
        XCTAssertEqual(Set(fixes.map(\.lat)).count, 1, "the position never changes")
        XCTAssertGreaterThan(spinning.compactMap(\.odometerKm).max() ?? 0, spinning.compactMap(\.odometerKm).min() ?? 0, "the wheel odometer still counts")
    }

    /// TRAP-KICK: current above 0.5 A and GPS above 8 km/h: this one is a real ride.
    func test_TRAPKICK_realStartConfirmsOnCurrentAndGps() throws {
        let stream = try scenario("TRAP-KICK")
        let late = frames(stream.scooter).filter { $0.t > 20 }
        XCTAssertTrue(late.contains { ($0.currentA ?? 0) > T.t11ConfirmCurrentA })
        let fast = stream.phone.compactMap(\.fix).filter { $0.t > 20 }
        XCTAssertFalse(fast.isEmpty)
        for fix in fast { XCTAssertGreaterThan(fix.speedMps * 3.6, T.t12ConfirmGpsKmh) }
        let p = { () -> ScooterPipeline in var p = ScooterPipeline(); p.handle(stream.scooter); return p }()
        XCTAssertEqual(p.plausibility.ignoredReadings, 0)
    }

    /// Synthetic streams replay on the shared clock like any other.
    func test_syntheticStreams_replayToTheEnd() throws {
        for s in SyntheticScenario.all {
            let session = ReplaySession(stream: s.build(), speed: 50)
            let all = session.runToEndAll()
            XCTAssertTrue(session.isFinished, s.id)
            XCTAssertFalse(all.scooter.isEmpty, s.id)
            XCTAssertFalse(all.phone.isEmpty, s.id)
        }
    }
}
