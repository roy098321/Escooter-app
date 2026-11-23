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

/// RND G500 status packet (20 bytes, starts 0x24 0x20) · PROTOCOL.md "RND G500" (B102, decoded from the owner's first ride
/// against GPS and the dashboard). One packet carries what the G2 splits over A and B. It has no odometer, no battery %
/// and no gear: those stay nil (never 0), and ride distance comes from the wheel speed.
public struct PacketG500: Equatable, Sendable {
    public let bytes: [UInt8]

    /// Wheel speed per raw unit (bytes 10–11), km/h: GPS speed ÷ raw, median of 448 fixes over 8 km/h. The dashboard's own
    /// km/h (byte 12) reads ~8 % higher, as speedometers do.
    public static let wheelKmhPerUnit = 0.0516
    /// Pack voltage range the readings may take (G500 rested at ~60.7 V full, sagged to ~55 V under load)
    public static let voltageRange = 42.0...68.0

    /// Battery voltage, V — bytes 4–5 LE ÷ 100 ✅ (sags with current)
    public var voltage: Double { Double(Decoder.le(bytes, 4, 2)) / 100 }
    /// Motor current, A — bytes 6–7 LE ÷ 100 🟡 (0.03 A standing, ~40 A at full pull; voltage sag follows it)
    public var currentA: Double { Double(Decoder.le(bytes, 6, 2)) / 100 }
    /// Wheel speed raw — bytes 10–11 LE
    public var speedRaw: Int { Decoder.le(bytes, 10, 2) }
    public var speedKmh: Double { Double(speedRaw) * Self.wheelKmhPerUnit }
    /// The speed the dashboard shows, km/h — byte 12
    public var dashboardKmh: Int { Int(bytes[12]) }
    /// Temperature, °C — bytes 14–15 LE ÷ 100 🟡 (~25 °C at rest, rises over a ride and keeps rising just after hard pulls)
    public var temperatureC: Double { Double(Decoder.le(bytes, 14, 2)) / 100 }
    /// Status bits — byte 18, as the G2's byte 4: 0x02 motor powered · 0x08 brake · 0x80 shutting down 🟡
    public var status: UInt8 { bytes[18] }
    public var motorPowered: Bool { status & 0x02 != 0 }
    public var brake: Bool { status & 0x08 != 0 }
    public var shuttingDown: Bool { status & 0x80 != 0 }
}

public enum ScooterPacket: Equatable, Sendable {
    case a(PacketA)
    case b(PacketB)
    /// B102: RND G500 (one packet with everything it sends)
    case g500(PacketG500)
    /// Any other length or layout: counted, never decoded (e.g. the 128-byte FF line)
    case unknown(length: Int)
}

/// Decoder · CALC_SPEC §1. Read-only: it has no encoder (that lives in CorckieSim, for tests only).
public enum Decoder {
    /// Raised whenever a decode rule changes, so old rides are re-computed from raw (DATA_MODEL V5).
    /// 2 = B102: strict G2 layout check + the RND G500 packet.
    public static let version = 2

    public static func decode(_ bytes: [UInt8]) -> ScooterPacket {
        if isG2PacketA(bytes) { return .a(PacketA(bytes: bytes)) }
        if bytes.count == 11 { return .b(PacketB(bytes: bytes)) }
        if isG500(bytes) { return .g500(PacketG500(bytes: bytes)) }
        return .unknown(length: bytes.count)
    }

    /// B102: the G2 (RND G100) packet A layout, checked byte by byte (PROTOCOL.md). "20 bytes ending in 0" alone
    /// also matches other scooters (the G500 read as 0 %, 0 km, 0.44 V), so the bytes that never change on a G2
    /// are checked too: byte 2 = 0, gear (byte 5) 1–3, battery % (byte 18) at most 100. Any other layout is
    /// unknown: counted, kept raw, never shown or stored as numbers.
    public static func isG2PacketA(_ b: [UInt8]) -> Bool {
        b.count == 20 && b[19] == 0 && b[2] == 0 && (1...3).contains(b[5]) && b[18] <= 100
    }

    /// B102: the RND G500 layout: 20 bytes starting 0x24 0x20 (constant on every packet seen), ending in 0. Bytes 2–3 are the
    /// scooter's own ID and are not checked (any G500 must match).
    public static func isG500(_ b: [UInt8]) -> Bool {
        b.count == 20 && b[0] == 0x24 && b[1] == 0x20 && b[19] == 0
    }

    /// Little-endian unsigned integer.
    static func le(_ b: [UInt8], _ start: Int, _ count: Int) -> Int {
        var value = 0
        for i in 0..<count { value |= Int(b[start + i]) << (8 * i) }
        return value
    }
}
