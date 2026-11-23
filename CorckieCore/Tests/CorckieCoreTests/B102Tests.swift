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
