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
    /// B73 (batch 3): a fresh packet B says "no temperature yet" (0xFFFF, before the motor first runs): clear, never keep an old value
    public var temperatureNoReading = false
    public var currentA: Double?
    /// Seconds since the last packet A / B
    public var ageA: Double?
    public var ageB: Double?
    /// B102: which scooter layout made the frame (the plausibility voltage range depends on the pack)
    public var layout: ScooterLayout = .g2

    public init(t: Double) {
        self.t = t
    }

    /// Power, W (voltage × current) · PROTOCOL "Derived"
    public var powerW: Double? {
        guard let v = voltage, let i = currentA else { return nil }
        return v * i
    }
}

/// B102: the data layouts the app can read
public enum ScooterLayout: String, Equatable, Sendable {
    case g2, g500

    /// Voltage readings outside this range are dropped (T05 for the G2's 48 V pack)
    public var voltageRange: ClosedRange<Double> {
        switch self {
        case .g2: return T.t05MinVoltage...T.t05MaxVoltage
        case .g500: return PacketG500.voltageRange
        }
    }
}

/// Keeps the latest A and B and builds a frame for every packet.
public struct FrameAssembler {
    /// Packet B values older than this count as missing (CALC_SPEC §1).
    public static let maxAgeBS = 2.0

    /// `.full`: one packet with both the A fields (speed, voltage, status) and the B fields (current, temperature): the G500
    public enum Kind: Sendable { case a, b, full }

    public private(set) var lastA: PacketA?
    public private(set) var lastATime: Double?
    public private(set) var lastB: PacketB?
    public private(set) var lastBTime: Double?
    public private(set) var lastG500: PacketG500?
    public private(set) var lastG500Time: Double?
    /// B102 (.05): G500 battery % from the resting voltage (it sends no %): the last rested reading of this connection
    public private(set) var g500RestPct: Int?
    private var g500RestSince: Double?
    /// B102 (.05): G500 temperature readings of the last `g500TempWindowS` (it dips 3–11 °C above ~48 km/h, even coasting)
    private var g500Temps: [(t: Double, c: Double)] = []
    /// Standing still at no current this long before the voltage counts as resting (the first reading of a connection
    /// counts at once: the scooter was just switched on)
    public static let g500RestS = 10.0
    public static let g500TempWindowS = 10.0
    public private(set) var packetCount = 0
    public private(set) var unknownCount = 0
    /// Which packet made the last frame
    public private(set) var lastKind: Kind?
    /// B102: since the last reset: packets A read, and packets of a layout we can't read (all-FF filler not counted)
    public private(set) var packetsASinceReset = 0
    public private(set) var foreignSinceReset = 0
    /// B102: connected, data arrives, but not in a layout we know: "Connected · numbers not supported yet"
    public var numbersUnsupported: Bool { packetsASinceReset == 0 && foreignSinceReset >= Self.foreignToDecide }
    /// Unknown packets (not all-FF) with no packet A, before the layout counts as not supported (a G2 sends A ~3× a second)
    public static let foreignToDecide = 3

    public init() {}

    /// Returns a frame for packet A / B, nil for an unknown packet.
    public mutating func ingest(_ bytes: [UInt8], at t: Double) -> ScooterFrame? {
        packetCount += 1
        switch Decoder.decode(bytes) {
        case .a(let a):
            packetsASinceReset += 1
            lastA = a
            lastATime = t
            lastKind = .a
        case .b(let b):
            lastB = b
            lastBTime = t
            lastKind = .b
        case .g500(let g):
            packetsASinceReset += 1
            lastG500 = g
            lastG500Time = t
            lastKind = .full
            noteG500(g, at: t)
        case .unknown:
            unknownCount += 1
            if !bytes.allSatisfy({ $0 == 0xFF }) { foreignSinceReset += 1 }
            return nil
        }
        return frame(at: t)
    }

    public func frame(at t: Double) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        if let g = lastG500, let tg = lastG500Time {
            // B102: odometer, battery %, gear, cap and headlight are not sent: they stay nil / off
            f.layout = .g500
            f.speedKmh = g.speedKmh
            f.voltage = g.voltage
            f.brake = g.brake
            f.shuttingDown = g.shuttingDown
            f.motorPowered = g.motorPowered
            f.ageA = t - tg
            f.ageB = t - tg
            if t - tg <= Self.maxAgeBS {
                f.temperatureC = g500Temps.map(\.c).max() ?? g.temperatureC   // B102 (.05): highest of the last 10 s
                f.currentA = g.currentA
            }
            f.batteryPct = g500RestPct      // B102 (.05): resting-voltage estimate, nil until the first rested reading
            return f
        }
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
                f.temperatureNoReading = b.temperatureC == nil
                f.currentA = b.currentA
            }
        }
        return f
    }

    /// B102 (.05): resting voltage -> % (model table pack), and the temperature window
    private mutating func noteG500(_ g: PacketG500, at t: Double) {
        g500Temps.append((t, g.temperatureC))
        g500Temps.removeAll { t - $0.t > Self.g500TempWindowS }
        let resting = g.currentA <= T.t40RestedCurrentA && g.speedRaw == 0
        if !resting {
            g500RestSince = nil
            return
        }
        if g500RestSince == nil { g500RestSince = t }
        let settled = t - (g500RestSince ?? t) >= Self.g500RestS
        guard settled || g500RestPct == nil,
              let pack = ScooterModels.pack(model: ScooterModels.model(for: .g500)),
              PacketG500.voltageRange.contains(g.voltage) else { return }
        g500RestPct = LiIonCurve.pct(packV: g.voltage, cells: pack.cells)
    }

    /// Forget the last packets (on disconnect).
    public mutating func reset() {
        lastA = nil
        lastATime = nil
        lastB = nil
        lastBTime = nil
        lastG500 = nil
        lastG500Time = nil
        g500RestPct = nil
        g500RestSince = nil
        g500Temps = []
        packetsASinceReset = 0
        foreignSinceReset = 0
    }
}
