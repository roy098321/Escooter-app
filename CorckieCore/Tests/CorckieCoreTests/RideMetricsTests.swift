import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// M1-06: ride metrics computed from stored samples (CALC_SPEC M4–M10, M38). Golden values come from
/// the recorded rides replayed through the real decoder + plausibility filter and sampled the way the
/// Recorder samples (`RideSampler`): ride 1 = 437 Wh / 16.3 km, ride 2 = 322 Wh / 13.7 km.
final class RideMetricsTests: XCTestCase {
    // MARK: Helpers

    private struct Run {
        var metrics: RideMetrics
        var samples: [RideSample]
        var pipeline: ScooterPipeline
    }

    private enum Item {
        case scooter(TimedScooterEvent)
        case phone(TimedPhoneEvent)
        var t: Double {
            switch self {
            case .scooter(let e): return e.t
            case .phone(let e): return e.t
            }
        }
    }

    private func shift(_ f: Fault, by s: Double) -> Fault {
        switch f {
        case let .disconnect(at, d): return .disconnect(at: at + s, durationS: d)
        case let .speedSpike(at, k): return .speedSpike(at: at + s, kmh: k)
        case let .batterySpike(at, p): return .batterySpike(at: at + s, points: p)
        default: return f
        }
    }

    /// A recorded ride → pipeline → samples every `interval` s → metrics. `withPhone` adds ride 2's GPS + barometer (F4).
    private func run(_ fixture: String, interval: Double, faults: [Fault] = [], withPhone: Bool = false,
                     stripOdometer: Bool = false) throws -> Run {
        let sim = try XCTUnwrap(SimFixture.all.first { $0.fileName == fixture })
        let text = try Fixtures.text(fixture + ".csv")
        let clean = try sim.events(from: text)
        let startT = clean.first?.t ?? 0
        let scooter = FaultInjector.apply(faults.map { shift($0, by: startT) }, to: clean)

        var items = scooter.map { Item.scooter($0) }
        if withPhone {
            let start = try XCTUnwrap(LogReader.mergedStartTimeOfDayS(text))
            let phone = try PhoneSource.events(locationText: Fixtures.text("F4_ride2_location.csv"),
                                               barometerText: Fixtures.text("F4_ride2_barometer.csv"),
                                               scooterStartTimeOfDayS: start)
            items += phone.map { Item.phone($0) }
        }
        items.sort { $0.t < $1.t }

        var pipeline = ScooterPipeline()
        var sampler = RideSampler(intervalS: interval)
        var samples: [RideSample] = []
        for item in items {
            switch item {
            case .phone(let e):
                if let f = e.fix { sampler.update(fix: f) }
                if let b = e.baro { sampler.update(baro: b) }
            case .scooter(let e):
                pipeline.handle(e)
                guard e.bytes != nil, let frame = pipeline.frame, frame.t == e.t else { continue }
                if var s = sampler.offer(frame, startT: startT) {
                    if stripOdometer { s.odometerKm = nil }
                    samples.append(s)
                }
            }
        }
        let metrics = RideMetricsCalculator.compute(samples, ignoredReadings: pipeline.plausibility.ignoredReadings)
        return Run(metrics: metrics, samples: samples, pipeline: pipeline)
    }

    /// 1 sample per second from a speed function (km/h); GPS optional.
    private func synthetic(seconds: Int, speed: (Int) -> Double, current: (Int) -> Double = { _ in 5 },
                           battery: (Int) -> Int = { _ in 90 }, gps: Bool = false,
                           gpsSpeed: ((Int) -> Double)? = nil, odometerStep: Bool = true) -> [RideSample] {
        var out: [RideSample] = []
        var km = 0.0
        for t in 0...seconds {
            if t > 0 { km += speed(t - 1) / 3600 }
            var s = RideSample(t: Double(t), speedKmh: speed(t), voltage: 50, currentA: current(t), batteryPct: battery(t), tempC: 30)
            s.odometerKm = odometerStep ? 100 + (km * 10).rounded(.down) / 10 : 100 + km
            if gps {
                s.lat = 10.0
                s.lon = -30.0
                s.hAccM = 5
                s.gpsSpeedKmh = gpsSpeed?(t) ?? speed(t)
            }
            out.append(s)
        }
        return out
    }

    // MARK: Golden values (rides 1 and 2)

    func test_golden_ride1_every1s() throws {
        let r = try run("F2_ride1_nrf", interval: 1)
        let m = r.metrics
        XCTAssertEqual(m.energyWhRaw, 437, accuracy: 437 * 0.03)
        XCTAssertEqual(m.distanceKm, 16.3, accuracy: 0.05)
        XCTAssertEqual(m.distanceSource, "odometer")
        XCTAssertEqual(m.topSpeedKmh, 50.7, accuracy: 1.0, "a real 50.7 km/h is kept (no fixed maximum)")
        XCTAssertEqual(m.tempPeakC ?? 0, 92, accuracy: 1)
        XCTAssertTrue((24...27).contains(m.tempStartC ?? 0), "starts at ~24–26 °C, got \(String(describing: m.tempStartC))")
        XCTAssertEqual(m.tempRiseC ?? 0, 92 - (m.tempStartC ?? 0), accuracy: 1)
        XCTAssertEqual(m.ignoredReadings, 0)
        XCTAssertFalse(m.showsIgnoredReadingsNote)
        XCTAssertEqual(m.gapScooterS, 0, accuracy: 6)
        XCTAssertFalse(m.hasGps)
        XCTAssertNil(m.elevGainM, "no barometer in the scooter log")
        XCTAssertTrue((1_500...2_600).contains(m.totalS), "a ~39 min ride, got \(m.totalS)")
        XCTAssertLessThanOrEqual(m.movingS, m.totalS)
        let avgKmh = (m.avgMovingMps ?? 0) * 3.6
        XCTAssertTrue((15...40).contains(avgKmh), "avg speed while moving \(avgKmh)")
        XCTAssertGreaterThan(m.stops, 0)
    }

    func test_golden_ride1_every5s_asTheRecorderStoresIt() throws {
        let r = try run("F2_ride1_nrf", interval: 5)
        XCTAssertEqual(r.metrics.energyWhRaw, 437, accuracy: 437 * 0.03)
        XCTAssertEqual(r.metrics.distanceKm, 16.3, accuracy: 0.15, "the last odometer step can fall between two samples")
        XCTAssertGreaterThan(r.metrics.topSpeedKmh, 40)
        XCTAssertLessThanOrEqual(r.metrics.topSpeedKmh, 51.7, "sampling can only miss the peak, never invent one")
        XCTAssertTrue((300...700).contains(r.samples.count), "a ~39 min ride every 5 s, got \(r.samples.count)")
        let gaps = zip(r.samples, r.samples.dropFirst()).map { $1.t - $0.t }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, 4.9)
    }

    func test_golden_ride2_rawPackets() throws {
        let r = try run("F5_ride2_nrf", interval: 1)
        XCTAssertEqual(r.metrics.energyWhRaw, 322, accuracy: 322 * 0.03)
        XCTAssertEqual(r.metrics.distanceKm, 13.7, accuracy: 0.05)
    }

    func test_golden_ride2_withPhoneGpsAndBarometer() throws {
        let r = try run("F3_ride2_merged", interval: 1, withPhone: true)
        let m = r.metrics
        XCTAssertEqual(m.energyWhRaw, 322, accuracy: 322 * 0.03)
        XCTAssertEqual(m.distanceKm, 13.7, accuracy: 0.05)
        XCTAssertTrue(m.hasGps)
        XCTAssertGreaterThan(m.topSpeedKmh, 25)
        let gain = try XCTUnwrap(m.elevGainM)
        let loss = try XCTUnwrap(m.elevLossM)
        XCTAssertGreaterThan(gain + loss, 0)
        XCTAssertLessThan(gain, 400)
        XCTAssertTrue(m.elevProvisional)
        if let used = m.usedPct { XCTAssertEqual(used, 41, accuracy: 3, "64% → 23% on ride 2") }
        if let pct = m.pctPerKm { XCTAssertEqual(pct, 41 / 13.7, accuracy: 0.3) }
    }

    /// Wheel speed integrated over time agrees with the odometer within 3% (PROTOCOL).
    func test_integratedSpeedMatchesOdometer_ride1() throws {
        let r = try run("F2_ride1_nrf", interval: 1, stripOdometer: true)
        XCTAssertEqual(r.metrics.distanceSource, "wheel")
        XCTAssertEqual(r.metrics.distanceKm, 16.3, accuracy: 16.3 * 0.03)
    }

    // MARK: Scenarios

    /// SC-15: spikes are dropped before they reach the samples; the note shows; the top speed stays real.
    func test_SC15_ignoredReadingsNote_andNoSpikeInTheTopSpeed() throws {
        let r = try run("F3_ride2_merged", interval: 1, faults: [.speedSpike(at: 200, kmh: 80), .batterySpike(at: 400, points: 20)])
        XCTAssertGreaterThan(r.metrics.ignoredReadings, 0)
        XCTAssertTrue(r.metrics.showsIgnoredReadingsNote)
        XCTAssertLessThan(r.metrics.topSpeedKmh, 60)
        XCTAssertEqual(r.metrics.distanceKm, 13.7, accuracy: 0.05)
    }

    /// A steady 50.7 km/h is a real speed: kept as it is.
    func test_steady50_7_isKept() {
        let samples = synthetic(seconds: 60, speed: { $0 < 3 ? 0 : 50.7 })
        let m = RideMetricsCalculator.compute(samples)
        XCTAssertEqual(m.topSpeedKmh, 50.7, accuracy: 0.001)
    }

    /// SC-01: a 60 s disconnect: the odometer fills the distance, no energy is invented, the gap is counted.
    func test_SC01_disconnect_gapCounted_distanceFromOdometer_noInventedEnergy() throws {
        let clean = try run("F3_ride2_merged", interval: 5)
        let r = try run("F3_ride2_merged", interval: 5, faults: [.disconnect(at: 600, durationS: 60)])
        XCTAssertEqual(r.metrics.distanceKm, 13.7, accuracy: 0.15)
        XCTAssertLessThan(r.metrics.energyWhRaw, clean.metrics.energyWhRaw)
        XCTAssertEqual(r.metrics.gapScooterS, 60, accuracy: 12)
        XCTAssertEqual(clean.metrics.gapScooterS, 0, accuracy: 6)
    }

    // MARK: Rules on synthetic samples

    func test_stopsAndMovingTime_useTheHysteresis() {
        // 0 for 5 s, 10 km/h for 20 s, stop 10 s, 10 km/h for 10 s, stop 4 s (short, but in the middle), 10 km/h 10 s, 0 after
        var profile: [Double] = Array(repeating: 0, count: 5) + Array(repeating: 10, count: 20) + Array(repeating: 0, count: 10)
        profile += Array(repeating: 10, count: 10) + Array(repeating: 0, count: 4) + Array(repeating: 10, count: 10) + Array(repeating: 0, count: 8)
        let samples = synthetic(seconds: profile.count - 1, speed: { profile[$0] })
        let m = RideMetricsCalculator.compute(samples)
        XCTAssertEqual(m.firstMoveT, 5)
        XCTAssertEqual(m.lastMoveT, 58)
        XCTAssertEqual(m.totalS, 53)
        XCTAssertEqual(m.stops, 2, "both stops of 3 s or more between moving stretches; the trailing standstill is the ride's end")
        XCTAssertEqual(m.movingS, 53 - 10 - 4, accuracy: 2)
        // the engine's stop rows win when given
        let withRows = RideMetricsCalculator.compute(samples, stops: [RideStopSpan(startT: 25, endT: 35)])
        XCTAssertEqual(withRows.stops, 1)
    }

    /// M3 flag from the engine beats the speed rule.
    func test_engineMovingFlag_isUsed() {
        var samples = synthetic(seconds: 20, speed: { _ in 10 })
        for i in samples.indices { samples[i].moving = i >= 5 && i <= 15 }
        let m = RideMetricsCalculator.compute(samples)
        XCTAssertEqual(m.firstMoveT, 5)
        XCTAssertEqual(m.totalS, 10)
    }

    /// TRAP-SPIN: the wheel turns on the stand (15 km/h), the phone stays put: that distance is not a ride (T32).
    func test_liftedWheel_isExcluded() {
        let samples = synthetic(seconds: 60, speed: { $0 < 5 ? 0 : 15 }, current: { _ in 0.3 }, gps: true, gpsSpeed: { _ in 0 })
        let m = RideMetricsCalculator.compute(samples)
        XCTAssertGreaterThan(m.liftedWheelM, 150)
        XCTAssertLessThan(m.distanceM, 60, "about 230 m of wheel turning, none of it travelled")
        XCTAssertEqual(m.topSpeedKmh, 0, "GPS stands still, so 15 km/h is not confirmed (M7)")
        // the same ride with the phone moving along is a real ride
        let real = synthetic(seconds: 60, speed: { $0 < 5 ? 0 : 15 }, gps: false)
        XCTAssertEqual(RideMetricsCalculator.compute(real).liftedWheelM, 0)
        XCTAssertGreaterThan(RideMetricsCalculator.compute(real).distanceM, 150)
        XCTAssertEqual(RideMetricsCalculator.compute(real).topSpeedKmh, 15, accuracy: 0.001, "no GPS fix: accepted")
    }

    func test_wheelFactor_scalesDistanceAndSpeed() {
        let samples = synthetic(seconds: 120, speed: { $0 < 3 ? 0 : 30 }, odometerStep: false)
        let plain = RideMetricsCalculator.compute(samples)
        let scaled = RideMetricsCalculator.compute(samples, wheelFactor: 1.05)
        XCTAssertEqual(scaled.distanceM, plain.distanceM * 1.05, accuracy: 0.5)
        XCTAssertEqual(scaled.topSpeedKmh, plain.topSpeedKmh * 1.05, accuracy: 0.001)
    }

    func test_restedBattery_usedPct_andPctPerKm() {
        // 5 s standing at 64%, 200 s at 36 km/h (2 km), then 25 s standing at < 0.2 A
        let samples = synthetic(seconds: 230,
                                speed: { $0 < 5 ? 0 : ($0 <= 205 ? 36 : 0) },
                                current: { $0 < 5 || $0 > 205 ? 0.05 : 12 },
                                battery: { $0 < 100 ? 64 : ($0 <= 205 ? 44 : 23) },
                                odometerStep: false)
        let m = RideMetricsCalculator.compute(samples)
        XCTAssertEqual(m.startRestPct, 64)
        XCTAssertEqual(m.endRestPct, 23)
        XCTAssertEqual(m.usedPct, 41)
        XCTAssertEqual(m.usedPctMethod, "rested")
        XCTAssertEqual(m.distanceKm, 2.0, accuracy: 0.02)
        XCTAssertEqual(m.pctPerKm ?? 0, 20.5, accuracy: 0.3)
        XCTAssertTrue(m.pctPerKmApproximate)
        XCTAssertTrue(m.pctPerKmText.hasPrefix("~20."), m.pctPerKmText)
        XCTAssertGreaterThan(m.energyWhRaw, 0)

        // standing only 15 s at the end: not rested (T40 = 20 s) → unknown, never guessed
        let short = RideMetricsCalculator.compute(Array(samples.prefix(221)))
        XCTAssertNil(short.endRestPct)
        XCTAssertNil(short.usedPct)

        // before 1 km (T43) the number is "—"
        let shortRide = synthetic(seconds: 130,
                                  speed: { $0 < 5 ? 0 : ($0 <= 105 ? 36 : 0) },
                                  current: { $0 < 5 || $0 > 105 ? 0.05 : 12 },
                                  battery: { $0 < 60 ? 64 : 60 }, odometerStep: false)
        let sm = RideMetricsCalculator.compute(shortRide)
        XCTAssertEqual(sm.distanceKm, 1.0, accuracy: 0.02)
        let tiny = RideMetricsCalculator.compute(Array(shortRide.prefix(60)))
        XCTAssertNil(tiny.pctPerKm)
        XCTAssertEqual(tiny.pctPerKmText, "—")
    }

    func test_elevation_hysteresis_spikeAndNoBarometer() {
        // up 10 m over 100 s, down 6 m over the next 60 s; one 30 m spike that must be dropped
        var samples: [RideSample] = []
        for t in 0...160 {
            var alt = t <= 100 ? 0.1 * Double(t) : 10 - 0.1 * Double(t - 100)
            if t == 50 { alt += 30 }
            var s = RideSample(t: Double(t), speedKmh: 20)
            s.altBaroM = alt
            samples.append(s)
        }
        let m = RideMetricsCalculator.compute(samples)
        XCTAssertEqual(m.elevGainM ?? 0, 10, accuracy: 2.0)
        XCTAssertEqual(m.elevLossM ?? 0, 6, accuracy: 2.0)
        XCTAssertTrue(m.elevProvisional)

        // noise of ±1 m is not climbing (2 m hysteresis)
        var noisy: [RideSample] = []
        for t in 0..<100 {
            var s = RideSample(t: Double(t), speedKmh: 20)
            s.altBaroM = t % 2 == 0 ? 0.9 : -0.9
            noisy.append(s)
        }
        XCTAssertEqual(RideMetricsCalculator.compute(noisy).elevGainM, 0)

        XCTAssertNil(RideMetricsCalculator.compute(synthetic(seconds: 30, speed: { _ in 10 })).elevGainM)
    }

    func test_heatWatch_hotAndVeryHot_onceEach_veryHotStaysUntilBelowHot() {
        var w = HeatWatch()
        XCTAssertNil(w.update(85))
        XCTAssertEqual(w.update(90), .hot)
        XCTAssertNil(w.update(91), "once per level")
        XCTAssertEqual(w.update(100), .veryHot)
        XCTAssertNil(w.update(95))
        XCTAssertEqual(w.level, .veryHot, "stays very hot until below hot")
        XCTAssertNil(w.update(89))
        XCTAssertEqual(w.level, .normal)
        XCTAssertNil(w.update(92), "hot was already announced this ride")
        XCTAssertEqual(w.level, .hot)
    }

    func test_distanceSeries_isMonotonic_andAnchoredToTheOdometer() throws {
        let r = try run("F2_ride1_nrf", interval: 1)
        let series = RideMetricsCalculator.distanceSeries(r.samples)
        XCTAssertEqual(series.count, r.samples.count)
        XCTAssertEqual(series.first, 0)
        XCTAssertEqual(zip(series, series.dropFirst()).filter { $1 < $0 }.count, 0, "never goes back")
        let last = try XCTUnwrap(series.last)
        XCTAssertEqual(last, r.metrics.distanceM, accuracy: 110, "within one odometer step of the final distance")
    }

    func test_emptyAndTinyInputs() {
        XCTAssertEqual(RideMetricsCalculator.compute([]), RideMetrics())
        let one = RideMetricsCalculator.compute([RideSample(t: 0, speedKmh: 0, voltage: 50, currentA: 1, batteryPct: 80)])
        XCTAssertEqual(one.totalS, 0)
        XCTAssertEqual(one.energyWhRaw, 0)
        XCTAssertNil(one.avgMovingMps)
    }
}
