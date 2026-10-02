import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// TESTING §1 layer 2 + §2 golden values: recorded P2 rides replayed through the fake
/// scooter (virtual clock) into the real decoder, plausibility filter and totals.
final class ReplayTests: XCTestCase {
    private func replay(_ fixture: String, faults: [Fault] = [], speed: Double = 50) throws -> ScooterPipeline {
        let sim = try XCTUnwrap(SimFixture.all.first { $0.fileName == fixture })
        let events = FaultInjector.apply(faults, to: try sim.events(from: Fixtures.text(fixture + ".csv")))
        let session = ReplaySession(events: events, speed: speed)
        var pipeline = ScooterPipeline()
        pipeline.handle(Array(session.runToEnd()))
        XCTAssertTrue(session.isFinished)
        return pipeline
    }

    /// Ride 1 energy (raw) ~437 Wh over ~16.3 km (±3%); temperature 26 → 92 °C (PROTOCOL, M38).
    func test_golden_ride1_energyDistanceTemperature() throws {
        let p = try replay("F2_ride1_nrf")
        XCTAssertEqual(p.totals.energyWhRaw, 437, accuracy: 437 * 0.03)
        XCTAssertEqual(p.totals.distanceKm, 16.3, accuracy: 0.05)
        XCTAssertEqual(p.totals.temperatureStartC, 26)
        XCTAssertEqual(p.totals.temperaturePeakC, 92)
        XCTAssertEqual(p.totals.gearCaps, [25])
        XCTAssertGreaterThan(p.totals.topSpeedKmh, 40)
        XCTAssertEqual(p.totals.topSpeedKmh, 50.7, accuracy: 1.0, "real top speed kept (no fixed maximum, P4 D1 A2)")
        XCTAssertEqual(p.plausibility.ignoredReadings, 0)
        XCTAssertFalse(p.plausibility.formatChanged, p.plausibility.formatChangeReason ?? "")
        XCTAssertEqual(p.assembler.unknownCount, 2)       // the 128-byte FF lines
    }

    /// Ride 2 energy ~322 Wh for 41% (→ 16 Ah pack, M37): raw packets and the 1-per-second log agree.
    func test_golden_ride2_rawPacketsAndSamplesAgree() throws {
        let raw = try replay("F5_ride2_nrf")
        XCTAssertEqual(raw.totals.energyWhRaw, 322, accuracy: 322 * 0.03)
        XCTAssertEqual(raw.totals.distanceKm, 13.7, accuracy: 0.05)
        XCTAssertFalse(raw.plausibility.formatChanged, raw.plausibility.formatChangeReason ?? "")

        let samples = try replay("F3_ride2_merged")
        XCTAssertEqual(samples.totals.energyWhRaw, 322, accuracy: 322 * 0.03)
        XCTAssertEqual(samples.totals.distanceKm, 13.7, accuracy: 0.05)
        XCTAssertEqual(samples.totals.batteryStartPct, 64)
        XCTAssertEqual(samples.totals.batteryEndPct, 23)
        XCTAssertEqual(samples.totals.temperaturePeakC, 84)
        // 322 Wh for 41% of a 48 V pack → about 16 Ah (T42 default)
        let packAh = samples.totals.energyWhRaw / 0.41 / T.t42PackVoltage
        XCTAssertEqual(packAh, T.t42DefaultPackAh, accuracy: 1.0)
    }

    /// F1 (P2 scooter session): modes 15 / 20 / 25, lowest speed 0.14, 649 × FFFF, 0x80 at 08:24:34.
    func test_golden_p2Session_modesLowestSpeedColdStartShutdown() throws {
        let text = try Fixtures.text("F1_p2lab_2oct.csv")
        let log = try LogReader.scooterLog(text)
        let p = try replay("F1_p2lab_2oct")
        XCTAssertEqual(p.totals.gearCaps, [15, 20, 25])
        XCTAssertEqual(p.totals.lowestMovingSpeedKmh ?? 0, 0.14, accuracy: 0.005)
        XCTAssertEqual(p.totals.noReadingTemperaturePackets, 649)
        let shutdown = try XCTUnwrap(p.totals.shutdownAt)
        let timeOfDay = (log.startTimeOfDayS ?? 0) + shutdown
        let expected: Double = 28_800 + 1_440 + 34             // 08:24:34
        XCTAssertEqual(timeOfDay, expected, accuracy: 1)
    }

    /// Odometer vs speed: integrated wheel speed within 3% of the odometer (PROTOCOL).
    func test_golden_ride1_integratedSpeedMatchesOdometer() throws {
        let log = try LogReader.scooterLog(Fixtures.text("F2_ride1_nrf.csv"))
        var km = 0.0
        var last: (t: Double, kmh: Double)?
        for e in log.events {
            guard let b = e.bytes, case .a(let a) = Decoder.decode(b) else { continue }
            if let l = last, e.t - l.t < 2 { km += l.kmh * (e.t - l.t) / 3600 }
            last = (e.t, a.speedKmh)
        }
        XCTAssertEqual(km, 16.3, accuracy: 16.3 * 0.03)
    }

    /// The virtual clock: 50× turns 36 s of wall time into 30 minutes of ride.
    func test_clock_50x() throws {
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == "F3" })
        let session = ReplaySession(events: try sim.events(from: Fixtures.text("F3_ride2_merged.csv")), speed: 50)
        var delivered = 0
        for _ in 0..<36 { delivered += session.advance(realSeconds: 1).count }
        XCTAssertGreaterThan(session.progress, 0.99)
        XCTAssertGreaterThan(delivered, 10_000)
        let started = Date()
        _ = try replay("F2_ride1_nrf")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a 39-min ride must replay in seconds")
    }
}
