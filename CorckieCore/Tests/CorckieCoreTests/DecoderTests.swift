import XCTest
@testable import CorckieCore

/// TESTING §3 "Decoder": every field of A and B, FFFF, unknown lengths, little-endian.
/// Golden packets are the PROTOCOL.md examples from the first ride log.
final class DecoderTests: XCTestCase {
    let exampleA = Hex.bytes("19 30 00 66 00 03 00 00 27 15 EA 16 00 00 22 28 1F 50 64 00")!
    let exampleB = Hex.bytes("2D 00 2C 01 88 17 22 22 C5 05 01")!

    func test_decode_packetA_everyField() throws {
        guard case .a(let a) = Decoder.decode(exampleA) else { return XCTFail("not packet A") }
        XCTAssertEqual(a.capKmh, 25)
        XCTAssertEqual(a.gear, 3)
        XCTAssertEqual(a.speedKmh, 0)
        XCTAssertEqual(a.voltage, 54.15, accuracy: 0.001)
        XCTAssertEqual(a.odometerKm, 586.6, accuracy: 0.001)
        XCTAssertEqual(a.flags, 0x22)
        XCTAssertEqual(a.batteryPct, 100)
        XCTAssertFalse(a.headlight)
        XCTAssertFalse(a.brake)
        XCTAssertFalse(a.shuttingDown)
        XCTAssertFalse(a.locked)
    }

    func test_decode_packetA_littleEndianAndBits() {
        var b = exampleA
        b[6] = 0x34; b[7] = 0x12            // 0x1234 = 4660 raw
        b[4] = 0x02 | 0x08 | 0x80           // motor, brake, shutting down
        b[17] = 0x51                        // headlight on
        guard case .a(let a) = Decoder.decode(b) else { return XCTFail("not packet A") }
        XCTAssertEqual(a.speedRaw, 4660)
        XCTAssertEqual(a.speedKmh, 4660 * 0.0476, accuracy: 1e-9)
        XCTAssertTrue(a.motorPowered)
        XCTAssertTrue(a.brake)
        XCTAssertTrue(a.shuttingDown)
        XCTAssertTrue(a.headlight)
    }

    func test_decode_lowestSpeed_isOneStepOf0_0476() {
        var b = exampleA
        b[6] = 3; b[7] = 0
        guard case .a(let a) = Decoder.decode(b) else { return XCTFail("not packet A") }
        XCTAssertEqual(a.speedKmh, 0.1428, accuracy: 0.0001)    // P2 T13: 0.14 km/h reported
    }

    func test_decode_packetB_everyField() {
        guard case .b(let b) = Decoder.decode(exampleB) else { return XCTFail("not packet B") }
        XCTAssertEqual(b.temperatureC, 45)
        XCTAssertEqual(b.currentLimitA, 30.0, accuracy: 0.001)
        XCTAssertEqual(b.currentA, 14.77, accuracy: 0.001)
    }

    func test_decode_packetB_FFFF_isNoReading() {
        let b = Hex.bytes("FF FF 2C 01 88 17 22 22 02 00 01")!
        guard case .b(let p) = Decoder.decode(b) else { return XCTFail("not packet B") }
        XCTAssertNil(p.temperatureC)
        XCTAssertEqual(p.currentA, 0.02, accuracy: 0.0001)
    }

    func test_decode_unknownLengths_areIgnored() {
        XCTAssertEqual(Decoder.decode([UInt8](repeating: 0xFF, count: 128)), .unknown(length: 128))
        XCTAssertEqual(Decoder.decode([0x01, 0x02]), .unknown(length: 2))
        var wrongMarker = exampleA
        wrongMarker[19] = 1
        XCTAssertEqual(Decoder.decode(wrongMarker), .unknown(length: 20))
    }

    func test_frame_keepsNewestValues_andDropsOldPacketB() {
        var assembler = FrameAssembler()
        XCTAssertNotNil(assembler.ingest(exampleB, at: 0))
        let f1 = assembler.ingest(exampleA, at: 0.3)
        XCTAssertEqual(f1?.currentA ?? -1, 14.77, accuracy: 0.001)
        XCTAssertEqual(f1?.voltage ?? -1, 54.15, accuracy: 0.001)
        XCTAssertEqual(f1?.powerW ?? -1, 54.15 * 14.77, accuracy: 0.01)
        let f2 = assembler.ingest(exampleA, at: 2.5)                 // B is 2.5 s old -> missing
        XCTAssertNil(f2?.currentA)
        XCTAssertNil(f2?.temperatureC)
        XCTAssertNil(assembler.ingest([UInt8](repeating: 0xFF, count: 128), at: 3))
        XCTAssertEqual(assembler.unknownCount, 1)
    }

    func test_hex_roundTrip() {
        XCTAssertEqual(Hex.bytes("1930 0066"), [0x19, 0x30, 0x00, 0x66])
        XCTAssertEqual(Hex.bytes("ab"), [0xAB])
        XCTAssertNil(Hex.bytes("ABC"))
        XCTAssertNil(Hex.bytes("ZZ"))
        XCTAssertEqual(Hex.string(exampleB), "2D 00 2C 01 88 17 22 22 C5 05 01")
    }

    func test_firmwareFingerprint_detectsChange() {
        var info = DeviceInfo()
        info.set(characteristic: "2A24", value: "BK-BLE-1.0")
        info.set(characteristic: "2A26", value: "6.1.2")
        XCTAssertNil(info.change(from: .p2Baseline), "not fully read yet")
        info.set(characteristic: "00002A28-0000-1000-8000-00805F9B34FB", value: "6.3.0")
        XCTAssertNil(info.change(from: .p2Baseline))
        info.set(characteristic: "2A26", value: "6.2.0")
        XCTAssertEqual(info.change(from: .p2Baseline), "Scooter firmware changed (6.1.2 → 6.2.0, software 6.3.0 → 6.3.0)")
    }

    func test_scooterIsRecognised_byNameOrRNDTag() {
        XCTAssertTrue(ScooterGatt.isScooter(name: "G2", manufacturerData: []))
        XCTAssertTrue(ScooterGatt.isScooter(name: nil, manufacturerData: [0xFF, 0xFF, 0x52, 0x4E, 0x44, 0xFF, 0x88, 0x17]))
        XCTAssertFalse(ScooterGatt.isScooter(name: "Other", manufacturerData: [0x52, 0x4E]))
    }
}
