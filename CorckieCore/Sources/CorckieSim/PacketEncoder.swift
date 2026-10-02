import CorckieCore
import Foundation

/// TEST-ONLY packet encoder (TESTING §2 "Sample replay"): turns decoded 1-per-second values
/// back into packets A / B so the real decoder can read them. It lives in CorckieSim and is
/// never linked into ScooterLink, which stays write-free (ReadOnlyGuardTests checks that).
public enum PacketEncoder {
    public struct Values: Equatable, Sendable {
        public var speedKmh: Double = 0
        public var voltage: Double = 50
        public var odometerKm: Double = 0
        public var batteryPct: Int = 100
        public var gear: Int = 3
        public var capKmh: Int = 25
        public var brake = false
        public var headlight = false
        public var shuttingDown = false
        /// nil = no reading yet (FFFF)
        public var temperatureC: Double?
        public var currentA: Double = 0

        public init() {}
    }

    public static func packetA(_ v: Values) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = UInt8(clamping: v.capKmh)
        b[1] = 0x30
        b[3] = 0x66
        b[4] = 0x02 | (v.brake ? 0x08 : 0) | (v.shuttingDown ? 0x80 : 0)
        b[5] = UInt8(clamping: v.gear)
        put(&b, 6, 2, Int((max(0, v.speedKmh) / T.t01WheelKmhPerUnit).rounded()))
        put(&b, 8, 2, Int((v.voltage * 100).rounded()))
        put(&b, 10, 4, Int((v.odometerKm * 10).rounded()))
        b[14] = 0x22 | (v.brake ? 0x08 : 0)
        b[15] = 0x28
        b[16] = 0x1F
        b[17] = 0x50 | (v.headlight ? 0x01 : 0)
        b[18] = UInt8(clamping: v.batteryPct)
        b[19] = 0
        return b
    }

    public static func packetB(_ v: Values) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 11)
        put(&b, 0, 2, v.temperatureC.map { Int($0.rounded()) } ?? 0xFFFF)
        put(&b, 2, 2, 300)
        b[4] = 0x88; b[5] = 0x17; b[6] = 0x22; b[7] = 0x22
        put(&b, 8, 2, Int((max(0, v.currentA) * 100).rounded()))
        b[10] = 0x01
        return b
    }

    /// Values of one merged sample (missing fields keep the previous values).
    public static func values(from s: MergedSample, previous: Values) -> Values {
        var v = previous
        if let x = s.scooterSpeedKmh { v.speedKmh = x }
        if let x = s.voltage { v.voltage = x }
        if let x = s.odometerKm { v.odometerKm = x }
        if let x = s.batteryPct { v.batteryPct = x }
        if let x = s.currentA { v.currentA = x }
        v.temperatureC = s.temperatureC ?? v.temperatureC
        v.brake = s.brake
        v.headlight = s.headlight
        return v
    }

    /// A 1-per-second log as a packet stream: A and B alternating ~3.4 per second each, like the scooter.
    public static func events(from samples: [MergedSample], packetsPerSecond: Int = 3) -> [TimedScooterEvent] {
        var out: [TimedScooterEvent] = []
        guard let first = samples.first else { return out }
        out.append(TimedScooterEvent(t: first.t, event: .connected))
        var v = Values()
        for s in samples {
            v = values(from: s, previous: v)
            let step = 1.0 / Double(max(1, packetsPerSecond))
            for k in 0..<max(1, packetsPerSecond) {
                let t = s.t + Double(k) * step
                out.append(TimedScooterEvent(t: t, event: .packet(packetA(v))))
                out.append(TimedScooterEvent(t: t + step / 2, event: .packet(packetB(v))))
            }
        }
        out.append(TimedScooterEvent(t: (samples.last?.t ?? 0) + 1, event: .disconnected))
        return out
    }

    private static func put(_ b: inout [UInt8], _ start: Int, _ count: Int, _ value: Int) {
        let v = max(0, value)
        for i in 0..<count { b[start + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
}
