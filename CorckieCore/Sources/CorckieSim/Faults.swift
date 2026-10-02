import CorckieCore
import Foundation

/// Scripted faults on a replay timeline (TESTING §2 "Fault injection", §4 scenarios).
/// Stream faults are applied here; phone-side faults (GPS loss, barometer stop, offline,
/// service down, battery level, relaunch) are carried as markers for the app layer and the
/// P5 ride engine, so a scenario can name them today.
public enum Fault: Equatable, Sendable {
    /// SC-01 / SC-02: the link drops at `at` for `durationS`, then reconnects
    case disconnect(at: Double, durationS: Double)
    /// Packets lost between two times (share 0…1)
    case packetLoss(from: Double, to: Double, share: Double)
    /// SC-04: bytes scrambled between two times (share of packets 0…1)
    case corruptBytes(from: Double, to: Double, share: Double)
    /// SC-15: one speed spike (km/h) at a time
    case speedSpike(at: Double, kmh: Double)
    /// SC-15: one battery % reading off by `points` at a time
    case batterySpike(at: Double, points: Int)
    /// T8: the 0x80 "shutting down" flag, then the link drops for good
    case shutdown(at: Double)
    // Markers for the app layer / P5 engine:
    case gpsLoss(from: Double, to: Double)
    case barometerStop(at: Double)
    case offline(from: Double, to: Double)
    case serviceDown(name: String)
    case phoneBattery(at: Double, pct: Int)
    case appRelaunch(at: Double)
}

public enum FaultInjector {
    /// Applies the stream faults; deterministic for a given seed.
    public static func apply(_ faults: [Fault], to input: [TimedScooterEvent], seed: UInt64 = 42) -> [TimedScooterEvent] {
        var rng = SplitMix64(seed: seed)
        var events = input
        for fault in faults {
            switch fault {
            case let .disconnect(at, durationS):
                events.removeAll { $0.t >= at && $0.t < at + durationS && $0.bytes != nil }
                events.append(TimedScooterEvent(t: at, event: .disconnected))
                events.append(TimedScooterEvent(t: at + durationS, event: .connected))
            case let .packetLoss(from, to, share):
                events.removeAll { $0.t >= from && $0.t <= to && $0.bytes != nil && rng.nextUnit() < share }
            case let .corruptBytes(from, to, share):
                events = events.map { e in
                    guard e.t >= from, e.t <= to, var b = e.bytes, rng.nextUnit() < share else { return e }
                    // Scramble the value bytes but keep the length and the A marker, like a format change
                    for i in b.indices where !(b.count == 20 && i == 19) {
                        b[i] = UInt8(truncatingIfNeeded: rng.next())
                    }
                    return TimedScooterEvent(t: e.t, event: .packet(b))
                }
            case let .speedSpike(at, kmh):
                if let i = events.firstIndex(where: { $0.t >= at && $0.bytes?.count == 20 }), var b = events[i].bytes {
                    let raw = Int((kmh / T.t01WheelKmhPerUnit).rounded())
                    b[6] = UInt8(raw & 0xFF)
                    b[7] = UInt8((raw >> 8) & 0xFF)
                    events[i] = TimedScooterEvent(t: events[i].t, event: .packet(b))
                }
            case let .batterySpike(at, points):
                if let i = events.firstIndex(where: { $0.t >= at && $0.bytes?.count == 20 }), var b = events[i].bytes {
                    b[18] = UInt8(clamping: Int(b[18]) + points)
                    events[i] = TimedScooterEvent(t: events[i].t, event: .packet(b))
                }
            case let .shutdown(at):
                if let i = events.firstIndex(where: { $0.t >= at && $0.bytes?.count == 20 }), var b = events[i].bytes {
                    b[4] |= 0x80
                    let t = events[i].t
                    events[i] = TimedScooterEvent(t: t, event: .packet(b))
                    events.removeAll { $0.t > t }
                    events.append(TimedScooterEvent(t: t + 0.5, event: .disconnected))
                }
            case .gpsLoss, .barometerStop, .offline, .serviceDown, .phoneBattery, .appRelaunch:
                break   // phone-side: read by the app layer / engine, not applied to the scooter stream
            }
        }
        return events.sorted { $0.t < $1.t }
    }
}

/// Small deterministic random numbers (same faults on every CI run).
public struct SplitMix64 {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
