import XCTest
@testable import CorckieCore
import CorckieSim

/// B102 (hotfix 111.291126.01): a scooter whose 20-byte packets also end in 0 but are not the G2 layout must not be read
/// as packet A (it showed 0 %, 0 km, 0.44 V). Synthetic packets only (no real scooter bytes in the public repo).
final class B102Tests: XCTestCase {
    /// G2 layout (PROTOCOL.md example)
    let g2 = Hex.bytes("19 30 00 66 00 03 00 00 27 15 EA 16 00 00 22 28 1F 50 64 00")!
    /// Synthetic "other layout": 20 bytes, ends in 0, byte 2 not 0, byte 5 not a gear
    let foreign = Hex.bytes("30 20 AB CD 10 27 02 00 32 00 00 00 00 00 05 0B 01 00 00 00")!

    func test_g2Layout_isPacketA() {
        XCTAssertTrue(Decoder.isG2PacketA(g2))
        guard case .a = Decoder.decode(g2) else { return XCTFail("G2 packet A not read") }
    }

    func test_otherLayout_endingInZero_isNotPacketA() {
        XCTAssertFalse(Decoder.isG2PacketA(foreign))
        XCTAssertEqual(Decoder.decode(foreign), .unknown(length: 20))
    }

    func test_eachG2Rule_rejectsOnItsOwn() {
        var b = g2; b[2] = 0x01
        XCTAssertFalse(Decoder.isG2PacketA(b), "byte 2 is always 0 on a G2")
        b = g2; b[5] = 0
        XCTAssertFalse(Decoder.isG2PacketA(b), "gear is 1–3")
        b = g2; b[5] = 4
        XCTAssertFalse(Decoder.isG2PacketA(b), "gear is 1–3")
        b = g2; b[18] = 101
        XCTAssertFalse(Decoder.isG2PacketA(b), "battery % at most 100")
        b = g2; b[19] = 1
        XCTAssertFalse(Decoder.isG2PacketA(b))
        XCTAssertFalse(Decoder.isG2PacketA(Array(g2.prefix(19))))
    }

    func test_simulatorPackets_stayG2_inEveryGear() {
        for gear in 1...3 {
            var v = PacketEncoder.Values()
            v.gear = gear
            v.batteryPct = 0
            XCTAssertTrue(Decoder.isG2PacketA(PacketEncoder.packetA(v)))
            v.batteryPct = 100
            XCTAssertTrue(Decoder.isG2PacketA(PacketEncoder.packetA(v)))
        }
    }

    func test_assembler_flagsUnsupportedLayout_noFrames() {
        var a = FrameAssembler()
        XCTAssertNil(a.ingest([UInt8](repeating: 0xFF, count: 128), at: 0))
        for i in 1...2 { XCTAssertNil(a.ingest(foreign, at: Double(i))) }
        XCTAssertFalse(a.numbersUnsupported, "not decided after 2")
        XCTAssertNil(a.ingest(foreign, at: 3))
        XCTAssertTrue(a.numbersUnsupported)
        XCTAssertNil(a.lastA)
        a.reset()
        XCTAssertFalse(a.numbersUnsupported, "decided again on every connection")
    }

    func test_assembler_allFFfiller_neverFlags() {
        var a = FrameAssembler()
        for i in 0..<10 { _ = a.ingest([UInt8](repeating: 0xFF, count: 128), at: Double(i)) }
        XCTAssertFalse(a.numbersUnsupported)
    }

    func test_assembler_g2_withSomeOddPackets_isSupported() {
        var a = FrameAssembler()
        XCTAssertNotNil(a.ingest(g2, at: 0))
        for i in 1...5 { _ = a.ingest(foreign, at: Double(i)) }
        XCTAssertFalse(a.numbersUnsupported)
    }

    func test_home_unsupported_showsNoNumbers() {
        var i = HomeInput(paired: true, connected: true, nowS: 0, batteryPct: 57)
        i.numbersUnsupported = true
        let m = HomeLogic.model(i)
        XCTAssertEqual(m.state, .ready)
        XCTAssertNil(m.batteryText)
        XCTAssertEqual(m.detail, "Numbers not supported yet")
        i.numbersUnsupported = false
        XCTAssertEqual(HomeLogic.model(i).batteryText, "57%")
    }

    /// B102 (.02): setup kept "searching" while the scooter was connected: its found check hung on a Timer publisher
    /// re-made on every Home redraw. It must follow the connection itself.
    func test_setup_followsTheConnection_notARemadeTimer() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let onboarding = try String(contentsOf: folder.appendingPathComponent("UI/Onboarding/OnboardingView.swift"), encoding: .utf8)
        XCTAssertFalse(onboarding.contains("Timer.publish"))
        XCTAssertTrue(onboarding.contains(".onChange(of: AppModel.shared.scooter.connected)"))
        XCTAssertTrue(onboarding.contains("AppModel.shared.scooter.confirmPairing()"))
    }

    // MARK: B102 step 2 · RND G500 decoder (synthetic packets; bytes 2–3 are a made-up ID)

    /// 59.04 V · 5.00 A · raw 1000 · dashboard 55 · 25.00 °C · motor powered
    let g500 = Hex.bytes("24 20 12 34 10 17 F4 01 2C 00 E8 03 37 00 C4 09 01 00 02 00")!

    func test_g500_everyField() {
        guard case .g500(let p) = Decoder.decode(g500) else { return XCTFail("not a G500 packet") }
        XCTAssertEqual(p.voltage, 59.04, accuracy: 1e-9)
        XCTAssertEqual(p.currentA, 5.0, accuracy: 1e-9)
        XCTAssertEqual(p.speedRaw, 1000)
        XCTAssertEqual(p.speedKmh, 51.6, accuracy: 1e-9)
        XCTAssertEqual(p.dashboardKmh, 55)
        XCTAssertEqual(p.temperatureC, 25.0, accuracy: 1e-9)
        XCTAssertTrue(p.motorPowered)
        XCTAssertFalse(p.brake)
        XCTAssertFalse(p.shuttingDown)
        XCTAssertFalse(Decoder.isG2PacketA(g500), "never read with the G2 layout")
    }

    func test_g500_frame_hasNoKmPercentOrGear() throws {
        var a = FrameAssembler()
        let f = try XCTUnwrap(a.ingest(g500, at: 0))
        XCTAssertEqual(a.lastKind, .full)
        XCTAssertFalse(a.numbersUnsupported)
        XCTAssertEqual(f.layout, .g500)
        XCTAssertNil(f.odometerKm)
        XCTAssertNil(f.batteryPct)
        XCTAssertNil(f.gear)
        XCTAssertNil(f.capKmh)
        XCTAssertEqual(f.speedKmh ?? -1, 51.6, accuracy: 1e-9)
        XCTAssertEqual(f.powerW ?? -1, 59.04 * 5, accuracy: 1e-6)
    }

    func test_g500_voltageKept_g2RangeStillApplies() {
        var p = Plausibility()
        var f = ScooterFrame(t: 0)
        f.layout = .g500
        f.voltage = 60.6
        XCTAssertEqual(p.check(f, isPacketA: true).frame.voltage, 60.6)
        var g = ScooterFrame(t: 1)
        g.voltage = 60.6
        XCTAssertNil(p.check(g, isPacketA: true).frame.voltage, "G2 pack: T05 still drops 60.6 V")
    }

    func test_g500_ride_speedEnergyAndNoOdometer() {
        var pipe = ScooterPipeline()
        pipe.handle(TimedScooterEvent(t: 0, event: .connected))
        for i in 0..<60 {          // 18 s at ~3.3 packets/s
            pipe.handle(TimedScooterEvent(t: Double(i) * 0.3, event: .packet(g500)))
        }
        XCTAssertEqual(pipe.totals.topSpeedKmh, 51.6, accuracy: 1e-6)
        XCTAssertGreaterThan(pipe.totals.energyWhRaw, 1.0)              // 295 W for ~17.7 s ≈ 1.45 Wh
        XCTAssertNil(pipe.totals.odometerStartKm)
        XCTAssertNil(pipe.totals.batteryStartPct)
        XCTAssertEqual(pipe.totals.temperaturePeakC ?? -1, 25.0, accuracy: 1e-9)
        XCTAssertNil(pipe.frame?.batteryPct)
    }
}

/// B102 (.04): connected to a scooter whose data the app can't read (no frames at all): a started ride must run on phone
/// GPS (phone mode: time, path, distance), not sit at 0 s with no path waiting for readings that never come.
final class B102PhoneFallbackTests: XCTestCase {
    func test_connectedWithoutReadings_rideFallsBackToPhoneGps() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.startPressed, at: 1)
        var north = 0.0
        for t in stride(from: 2.0, through: 60, by: 1) {
            north += 20 / 3.6
            e.handle(.fix(PhoneFix(t: t, lat: 10 + north / 111_320, lon: -30, hAccM: 5, speedMps: 20 / 3.6)), at: t)
            e.handle(.tick, at: t)
        }
        XCTAssertTrue(e.rideActive)
        XCTAssertNotNil(e.scooterGoneSince(at: 60), "no readings this connection: the scooter counts as gone")
        XCTAssertTrue(e.phoneMode(at: 60), "the ride runs on phone GPS")
        XCTAssertGreaterThan(e.ride?.wheelM ?? 0, 150, "GPS distance is counted")
    }

    func test_connectedWithReadings_staysOnTheScooter() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        var f = ScooterFrame(t: 0.5)
        f.speedKmh = 0
        f.voltage = 50
        e.handle(.frame(f), at: 0.5)
        XCTAssertNil(e.scooterGoneSince(at: 1))
    }
}

/// B102 (.05): G500 battery % from the resting voltage, smoothed temperature, the quiet byte watch. Synthetic packets only.
final class B102G500BatteryAndWatchTests: XCTestCase {
    /// A synthetic G500 packet (made-up ID 12 34)
    func packet(volts: Double, amps: Double = 0.03, raw: Int = 0, tempC: Double = 25, status: UInt8 = 0,
                b8: UInt8 = 0x2C, b16: UInt8 = 1, b17: UInt8 = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x24; b[1] = 0x20; b[2] = 0x12; b[3] = 0x34
        func put(_ i: Int, _ v: Int) { b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8((v >> 8) & 0xFF) }
        put(4, Int((volts * 100).rounded())); put(6, Int((amps * 100).rounded())); b[8] = b8
        put(10, raw); b[12] = UInt8(min(255, Int(Double(raw) * 0.056))); put(14, Int((tempC * 100).rounded()))
        b[16] = b16; b[17] = b17; b[18] = status
        return b
    }

    func test_models_packFromTheTable() {
        XCTAssertEqual(ScooterModels.pack(model: "RND G500")?.packAh, 21)
        XCTAssertEqual(ScooterModels.pack(model: "RND G500")?.cells, 16)
        XCTAssertEqual(ScooterModels.pack(model: "RND G500")?.fullV ?? 0, 67.2, accuracy: 1e-9)
        XCTAssertEqual(ScooterModels.pack(model: "RND G100")?.packAh, T.t42DefaultPackAh, "the G100 keeps 16 Ah")
        XCTAssertNil(ScooterModels.pack(model: "Scooter"))
    }

    func test_curve_endsAndMiddle() {
        XCTAssertEqual(LiIonCurve.pct(packV: 67.2, cells: 16), 100)
        XCTAssertEqual(LiIonCurve.pct(packV: 70, cells: 16), 100)
        XCTAssertEqual(LiIonCurve.pct(packV: 52.8, cells: 16), 0)
        XCTAssertEqual(LiIonCurve.pct(cellV: 3.82), 50)
        XCTAssertEqual(LiIonCurve.pct(cellV: 4.05), 85)
        var last = -1
        for mv in stride(from: 3300, through: 4200, by: 10) {
            let p = LiIonCurve.pct(cellV: Double(mv) / 1000)
            XCTAssertGreaterThanOrEqual(p, last, "never falls as the voltage rises")
            last = p
        }
    }

    func test_battery_firstReadingAtOnce_thenOnlyAtRest() throws {
        var a = FrameAssembler()
        let first = try XCTUnwrap(a.ingest(packet(volts: 64.0), at: 0))
        XCTAssertEqual(first.batteryPct, LiIonCurve.pct(cellV: 4.0))       // switched on: rested
        // riding: the sagging voltage never changes the %; .06: the charge used counts it down (20 A for 30 s = 0.17 Ah of 21 = 0.8 %)
        for i in 1...30 {
            let f = try XCTUnwrap(a.ingest(packet(volts: 58.0, amps: 20, raw: 600), at: Double(i)))
            XCTAssertGreaterThanOrEqual(f.batteryPct ?? 0, 79, "the sag is not read as a drop")
        }
        // standing, no current: B113 (.11) the voltage is only trusted 5 min after the last load; until then the counted level
        var f = try XCTUnwrap(a.ingest(packet(volts: 63.2), at: 31))
        XCTAssertEqual(f.batteryPct, 79, "not yet rested: the counted level")
        f = try XCTUnwrap(a.ingest(packet(volts: 63.2), at: 41.5))
        XCTAssertEqual(f.batteryPct, 79, "10 s after riding is still a tired pack: the counted level")
        for i in 0..<35 { f = try XCTUnwrap(a.ingest(packet(volts: 63.2), at: 42 + Double(i) * 8)) }
        XCTAssertEqual(f.batteryPct, 79, "4.5 min after riding: still the counted level")
        f = try XCTUnwrap(a.ingest(packet(volts: 63.2), at: 30 + FrameAssembler.g500RecoverS + 1))
        XCTAssertEqual(f.batteryPct, LiIonCurve.pct(cellV: 3.95), "5 min after the load: the resting voltage counts")
        a.reset()
        XCTAssertNil(a.g500RestPct)
    }

    /// .06: the 24 Nov commute read 89 for 12 min with no 10 s stop, then 63. Riding without stops now counts the Ah used.
    func test_battery_countsDownWhileRiding_noStops() throws {
        var a = FrameAssembler()
        _ = a.ingest(packet(volts: 66.3), at: 0)                            // switched on: rested, 4.14 V a cell
        let start = try XCTUnwrap(a.g500RestPct)
        // 12 min at 30 A, 3 packets a second, never standing: 6 Ah = 28.6 % of 21 Ah
        var t = 0.0
        for _ in 0..<(12 * 60 * 3) {
            t += 1.0 / 3
            _ = a.ingest(packet(volts: 59.0, amps: 30, raw: 900), at: t)
        }
        let now = try XCTUnwrap(a.g500RestPct)
        XCTAssertEqual(Double(start - now), 6.0 / 21 * 100, accuracy: 1.0, "the counted level falls with the charge used")
    }

    /// .06: a gap in the packets is not guessed (at most 2 s counted per step)
    func test_battery_gapIsNotCounted() throws {
        var a = FrameAssembler()
        _ = a.ingest(packet(volts: 64.0), at: 0)
        _ = a.ingest(packet(volts: 58.0, amps: 30, raw: 900), at: 1)
        let f = try XCTUnwrap(a.ingest(packet(volts: 58.0, amps: 30, raw: 900), at: 600))   // 10 min without packets
        XCTAssertGreaterThanOrEqual(f.batteryPct ?? 0, 79)
    }

    /// .06 hysteresis: standing, a rested reading 1 point off the shown % keeps the shown one
    func test_battery_standingDoesNotFlicker() throws {
        var a = FrameAssembler()
        _ = a.ingest(packet(volts: 64.0), at: 0)
        let shown = try XCTUnwrap(a.g500RestPct)
        let oneOff = 16 * 3.993                                           // a cell voltage 1 point lower on the curve
        XCTAssertEqual(abs(LiIonCurve.pct(packV: oneOff, cells: 16) - shown), 1)
        for i in 1...40 { _ = a.ingest(packet(volts: oneOff), at: Double(i) * 0.5) }
        XCTAssertEqual(a.g500RestPct, shown, "a 1-point wobble at rest is not shown")
    }

    func test_battery_neverFromALoadedFirstPacket() throws {
        var a = FrameAssembler()
        let f = try XCTUnwrap(a.ingest(packet(volts: 55, amps: 30, raw: 900), at: 0))
        XCTAssertNil(f.batteryPct, "no rested reading yet: empty, never a guess under load")
    }

    func test_temperature_highestOfTheLast10s() throws {
        var a = FrameAssembler()
        _ = a.ingest(packet(volts: 60, tempC: 50), at: 0)
        var f = try XCTUnwrap(a.ingest(packet(volts: 60, amps: 10, raw: 1000, tempC: 42), at: 5))
        XCTAssertEqual(f.temperatureC ?? 0, 50, accuracy: 1e-9, "the dip above ~48 km/h is smoothed away")
        f = try XCTUnwrap(a.ingest(packet(volts: 60, amps: 10, raw: 1000, tempC: 42), at: 11))
        XCTAssertEqual(f.temperatureC ?? 0, 42, accuracy: 1e-9)
    }

    func test_g500Ride_batteryThroughThePipeline() {
        var pipe = ScooterPipeline()
        pipe.handle(TimedScooterEvent(t: 0, event: .connected))
        for i in 0..<20 { pipe.handle(TimedScooterEvent(t: Double(i) * 0.3, event: .packet(packet(volts: 62.0)))) }
        XCTAssertEqual(pipe.frame?.layout, .g500)
        XCTAssertNotNil(pipe.frame?.voltage)
        XCTAssertEqual(pipe.assembler.g500RestPct, LiIonCurve.pct(packV: 62.0, cells: 16))
    }

    func test_watch_firstValuesThenOnlyChanges() {
        var w = ByteWatch()
        w.connected(id: "c1")
        let first = w.observe(packet(volts: 60), atMs: 1_000)
        XCTAssertEqual(first.map(\.field), ["b8-9", "b16", "b17", "b18-other"])
        XCTAssertTrue(first.allSatisfy { $0.old == nil && $0.connection == "c1" })
        XCTAssertEqual(first.first?.new, 44)
        XCTAssertTrue(w.observe(packet(volts: 59.9, status: 0x0A), atMs: 1_300).isEmpty, "known status bits are not logged")
        let change = w.observe(packet(volts: 59.8, amps: 3, raw: 200, b17: 5), atMs: 1_600)
        XCTAssertEqual(change.count, 1)
        XCTAssertEqual(change.first?.field, "b17")
        XCTAssertEqual(change.first?.old, 0)
        XCTAssertEqual(change.first?.new, 5)
        XCTAssertEqual(change.first?.currentA ?? 0, 3, accuracy: 1e-9)
        XCTAssertNotNil(change.first?.rawBefore)
        let odd = w.observe(packet(volts: 59.8, status: 0x20, b17: 5), atMs: 1_900)
        XCTAssertEqual(odd.map(\.field), ["b18-other"])
        XCTAssertEqual(odd.first?.new, 0x20)
        w.connected(id: "c2")
        XCTAssertEqual(w.observe(packet(volts: 60), atMs: 2_000).count, 4, "first values again on a new connection")
        XCTAssertTrue(w.observe([UInt8](repeating: 0xFF, count: 128), atMs: 2_100).isEmpty)
    }

    func test_watch_capped() {
        let day: Int64 = 24 * 3_600_000
        let e = ByteWatchEntry(atMs: 0, connection: "c", field: "b17", old: nil, new: 0, speedKmh: 0, currentA: 0,
                               voltage: 60, temperatureC: 25, status: 0, rawBefore: nil, rawAfter: "")
        var list = [ByteWatchEntry](repeating: e, count: 700)
        for i in list.indices { list[i].atMs = Int64(i) * 3_600_000 }
        let kept = ByteWatch.trimmed(list, nowMs: 699 * 3_600_000)
        XCTAssertEqual(kept.count, 500)
        XCTAssertEqual(kept.last?.atMs, 699 * 3_600_000)
        XCTAssertTrue(ByteWatch.trimmed([e], nowMs: 61 * day).isEmpty, "older than 60 days")
    }
}
