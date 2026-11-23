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
}
