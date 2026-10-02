import Foundation

/// The newest value of every scooter field, emitted once per packet · CALC_SPEC §1 "Frame".
/// Times are seconds on the caller's clock (real or virtual).
public struct ScooterFrame: Equatable, Sendable {
    public var t: Double
    public var speedKmh: Double?
    public var voltage: Double?
    public var odometerKm: Double?
    public var batteryPct: Int?
    public var gear: Int?
    public var capKmh: Int?
    public var brake = false
    public var headlight = false
    public var locked = false
    public var shuttingDown = false
    public var motorPowered = false
    /// nil = no reading yet, or packet B older than 2 s
    public var temperatureC: Double?
    public var currentA: Double?
    /// Seconds since the last packet A / B
    public var ageA: Double?
    public var ageB: Double?

    public init(t: Double) {
        self.t = t
    }

    /// Power, W (voltage × current) · PROTOCOL "Derived"
    public var powerW: Double? {
        guard let v = voltage, let i = currentA else { return nil }
        return v * i
    }
}

/// Keeps the latest A and B and builds a frame for every packet.
public struct FrameAssembler {
    /// Packet B values older than this count as missing (CALC_SPEC §1).
    public static let maxAgeBS = 2.0

    public enum Kind: Sendable { case a, b }

    public private(set) var lastA: PacketA?
    public private(set) var lastATime: Double?
    public private(set) var lastB: PacketB?
    public private(set) var lastBTime: Double?
    public private(set) var packetCount = 0
    public private(set) var unknownCount = 0
    /// Which packet made the last frame
    public private(set) var lastKind: Kind?

    public init() {}

    /// Returns a frame for packet A / B, nil for an unknown packet.
    public mutating func ingest(_ bytes: [UInt8], at t: Double) -> ScooterFrame? {
        packetCount += 1
        switch Decoder.decode(bytes) {
        case .a(let a):
            lastA = a
            lastATime = t
            lastKind = .a
        case .b(let b):
            lastB = b
            lastBTime = t
            lastKind = .b
        case .unknown:
            unknownCount += 1
            return nil
        }
        return frame(at: t)
    }

    public func frame(at t: Double) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        if let a = lastA, let ta = lastATime {
            f.speedKmh = a.speedKmh
            f.voltage = a.voltage
            f.odometerKm = a.odometerKm
            f.batteryPct = a.batteryPct
            f.gear = a.gear
            f.capKmh = a.capKmh
            f.brake = a.brake
            f.headlight = a.headlight
            f.locked = a.locked
            f.shuttingDown = a.shuttingDown
            f.motorPowered = a.motorPowered
            f.ageA = t - ta
        }
        if let b = lastB, let tb = lastBTime {
            f.ageB = t - tb
            if t - tb <= Self.maxAgeBS {
                f.temperatureC = b.temperatureC
                f.currentA = b.currentA
            }
        }
        return f
    }

    /// Forget the last packets (on disconnect).
    public mutating func reset() {
        lastA = nil
        lastATime = nil
        lastB = nil
        lastBTime = nil
    }
}
