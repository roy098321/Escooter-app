import Foundation

/// Packet A (20 bytes, byte 19 = 0) · CALC_SPEC §1, PROTOCOL.md.
public struct PacketA: Equatable, Sendable {
    public let bytes: [UInt8]

    /// Speed cap of the current mode, km/h (15 / 20 / 25) ✅ — byte 0
    public var capKmh: Int { Int(bytes[0]) }
    /// Status bits — byte 4: 0x02 motor powered · 0x08 brake · 0x40 locked 🟡 · 0x80 shutting down
    public var status: UInt8 { bytes[4] }
    /// Mode / gear 1 / 2 / 3 ✅ — byte 5
    public var gear: Int { Int(bytes[5]) }
    /// Wheel speed in raw units — bytes 6–7 LE
    public var speedRaw: Int { Decoder.le(bytes, 6, 2) }
    /// Wheel speed, km/h (raw × T01)
    public var speedKmh: Double { Double(speedRaw) * T.t01WheelKmhPerUnit }
    /// Battery voltage, V — bytes 8–9 LE ÷ 100
    public var voltage: Double { Double(Decoder.le(bytes, 8, 2)) / 100 }
    /// Odometer, km — bytes 10–13 LE ÷ 10
    public var odometerKm: Double { Double(Decoder.le(bytes, 10, 4)) / 10 }
    /// Flags — byte 14 (0x08 brake mirror; 0x10 locked per the RND app; others kept raw)
    public var flags: UInt8 { bytes[14] }
    /// Battery %, 0–100 (bounces under load) — byte 18
    public var batteryPct: Int { Int(bytes[18]) }

    public var motorPowered: Bool { status & 0x02 != 0 }
    public var brake: Bool { status & 0x08 != 0 }
    /// 🟡 not confirmed on this scooter yet (T7 carried into P6)
    public var locked: Bool { status & 0x40 != 0 || flags & 0x10 != 0 }
    /// ✅ sent when the scooter switches itself off (e.g. charger plugged in)
    public var shuttingDown: Bool { status & 0x80 != 0 }
    /// ✅ headlight — byte 17 bit 0x01
    public var headlight: Bool { bytes[17] & 0x01 != 0 }
}

/// Packet B (11 bytes) · CALC_SPEC §1.
public struct PacketB: Equatable, Sendable {
    public let bytes: [UInt8]

    /// Temperature raw — bytes 0–1 LE; 0xFFFF = no reading yet (before the motor first runs)
    public var temperatureRaw: Int { Decoder.le(bytes, 0, 2) }
    /// °C, or nil while the scooter has no reading ("—" in the UI, never 0)
    public var temperatureC: Double? { temperatureRaw == 0xFFFF ? nil : Double(temperatureRaw) }
    /// Hypothesis: controller current limit, A — bytes 2–3 LE ÷ 10 (kept raw)
    public var currentLimitA: Double { Double(Decoder.le(bytes, 2, 2)) / 10 }
    /// Motor current, A — bytes 8–9 LE ÷ 100 🟡 (scale learned by M8)
    public var currentA: Double { Double(Decoder.le(bytes, 8, 2)) / 100 }
}

public enum ScooterPacket: Equatable, Sendable {
    case a(PacketA)
    case b(PacketB)
    /// Any other length or layout: counted, never decoded (e.g. the 128-byte FF line)
    case unknown(length: Int)
}

/// Decoder · CALC_SPEC §1. Read-only: it has no encoder (that lives in CorckieSim, for tests only).
public enum Decoder {
    /// Raised whenever a decode rule changes, so old rides are re-computed from raw (DATA_MODEL V5).
    public static let version = 1

    public static func decode(_ bytes: [UInt8]) -> ScooterPacket {
        if bytes.count == 20 && bytes[19] == 0 { return .a(PacketA(bytes: bytes)) }
        if bytes.count == 11 { return .b(PacketB(bytes: bytes)) }
        return .unknown(length: bytes.count)
    }

    /// Little-endian unsigned integer.
    static func le(_ b: [UInt8], _ start: Int, _ count: Int) -> Int {
        var value = 0
        for i in 0..<count { value |= Int(b[start + i]) << (8 * i) }
        return value
    }
}
