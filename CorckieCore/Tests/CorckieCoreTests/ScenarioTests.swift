import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// TESTING §1 layer 3: fallbacks with injected faults. The first ones the foundation can
/// check without the P5 ride engine: G1b (plausibility, format change) and the link events.
final class ScenarioTests: XCTestCase {
    private func ride2(_ faults: [Fault]) throws -> ScooterPipeline {
        let sim = try XCTUnwrap(SimFixture.all.first { $0.id == "F3" })
        let clean = try sim.events(from: Fixtures.text("F3_ride2_merged.csv"))
        let start = clean.first?.t ?? 0
        let events = FaultInjector.apply(faults.map { shift($0, by: start) }, to: clean)
        var p = ScooterPipeline()
        p.handle(events)
        return p
    }

    private func shift(_ f: Fault, by s: Double) -> Fault {
        switch f {
        case let .disconnect(at, d): return .disconnect(at: at + s, durationS: d)
        case let .corruptBytes(a, b, share): return .corruptBytes(from: a + s, to: b + s, share: share)
        case let .speedSpike(at, k): return .speedSpike(at: at + s, kmh: k)
        case let .batterySpike(at, p): return .batterySpike(at: at + s, points: p)
        case let .shutdown(at): return .shutdown(at: at + s)
        default: return f
        }
    }

    func test_SC00_cleanRide_noReadingsIgnored() throws {
        let p = try ride2([])
        XCTAssertEqual(p.plausibility.ignoredReadings, 0)
        XCTAssertFalse(p.plausibility.formatChanged)
    }

    /// SC-01: disconnect 60 s while moving → link events, totals keep counting from the odometer.
    func test_SC01_disconnectWhileMoving() throws {
        let p = try ride2([.disconnect(at: 600, durationS: 60)])
        XCTAssertEqual(p.disconnects, 2)                  // the injected one + the end of the log
        XCTAssertEqual(p.connects, 2)
        XCTAssertEqual(p.totals.distanceKm, 13.7, accuracy: 0.05, "odometer fills the gap")
        XCTAssertLessThan(p.totals.energyWhRaw, 322, "no energy is invented for the gap")
        XCTAssertFalse(p.plausibility.formatChanged)
    }

    /// SC-04: 30% corrupt packets → "Scooter data format changed" (T07).
    func test_SC04_corruptPackets_tripTheFormatWatch() throws {
        let p = try ride2([.corruptBytes(from: 120, to: 400, share: 0.3)])
        XCTAssertTrue(p.plausibility.formatChanged)
        XCTAssertGreaterThan(p.plausibility.ignoredReadings, 50)
    }

    /// SC-15: spikes are dropped, the ride is kept; "Some scooter readings were ignored".
    func test_SC15_spikesDropped() throws {
        let p = try ride2([.speedSpike(at: 200, kmh: 80), .batterySpike(at: 400, points: 20)])
        XCTAssertGreaterThan(p.plausibility.ignoredReadings, 0)
        XCTAssertLessThan(p.totals.topSpeedKmh, 60, "the 80 km/h spike is dropped by the step check")
        XCTAssertFalse(p.plausibility.formatChanged)
    }

    /// T8 / M2 A2: the 0x80 flag, then the link drops.
    func test_T8_shutdownFlagThenDisconnect() throws {
        let p = try ride2([.shutdown(at: 900)])
        XCTAssertNotNil(p.totals.shutdownAt)
        XCTAssertFalse(p.connected)
        XCTAssertLessThan(p.now, 905)
    }

    func test_G1b_limits_justInsideAndOutside() {
        func frame(_ t: Double, kmh: Double, volts: Double = 50, pct: Int = 80, odo: Double = 100) -> ScooterFrame {
            var f = ScooterFrame(t: t)
            f.speedKmh = kmh; f.voltage = volts; f.batteryPct = pct; f.odometerKm = odo
            return f
        }
        var g = Plausibility()
        XCTAssertTrue(g.check(frame(0, kmh: 45), isPacketA: true).dropped.isEmpty)
        XCTAssertTrue(g.check(frame(0.3, kmh: 50.7), isPacketA: true).dropped.isEmpty, "no fixed maximum (P4 D1 A2)")
        XCTAssertEqual(g.check(frame(0.6, kmh: 20), isPacketA: true).dropped, [.speed], "step > 15 km/h in 1 s")
        XCTAssertEqual(g.check(frame(5, kmh: 20, volts: 38.9), isPacketA: true).dropped, [.voltage])
        XCTAssertTrue(g.check(frame(6, kmh: 20, volts: 39.0), isPacketA: true).dropped.isEmpty)
        XCTAssertEqual(g.check(frame(7, kmh: 20, pct: 86), isPacketA: true).dropped, [.battery])
        XCTAssertTrue(g.check(frame(8, kmh: 20, pct: 85), isPacketA: true).dropped.isEmpty)
        XCTAssertEqual(g.check(frame(9, kmh: 20, odo: 99.9), isPacketA: true).dropped, [.odometer], "backwards")
        var hot = ScooterFrame(t: 10)
        hot.temperatureC = 131
        XCTAssertEqual(g.check(hot, isPacketA: false).dropped, [.temperature])
    }

    /// P4 D1 A2: a steady 50.7 km/h (ride 1's real top speed) is kept for minutes.
    func test_G1b_steadyHighSpeedIsKept() {
        var g = Plausibility()
        g.connected(at: 0)
        var odo = 600.0
        for i in 0..<600 {
            let t = Double(i) * 0.3
            var f = ScooterFrame(t: t)
            f.speedKmh = 50.7
            f.voltage = 50
            f.batteryPct = 70
            odo += 50.7 * 0.3 / 3600
            f.odometerKm = (odo * 10).rounded() / 10
            XCTAssertTrue(g.check(f, isPacketA: true).dropped.isEmpty, "dropped at \(t) s")
        }
        XCTAssertFalse(g.formatChanged)
        XCTAssertEqual(g.ignoredReadings, 0)
    }

    func test_formatWatch_noPacketAFor10s() {
        var g = Plausibility()
        g.connected(at: 0)
        g.tick(at: 30)
        XCTAssertFalse(g.formatChanged, "not armed before the first packet")
        _ = g.check(ScooterFrame(t: 31), isPacketA: false)     // a packet B arms the watch
        g.tick(at: 40)
        XCTAssertFalse(g.formatChanged)
        g.tick(at: 41.5)
        XCTAssertTrue(g.formatChanged)
    }

    func test_scenarioCatalog_playableOnesProduceFaults() {
        for s in SimScenario.all where s.playable && s.id != "clean" {
            XCTAssertFalse(s.faults(0).isEmpty, s.id)
        }
    }
}
