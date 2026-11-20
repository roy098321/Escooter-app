import Foundation

// N10 (batch 10): fault recognition. HARSH RULE (owner 20 Nov 2026): little to no false alarms. Every fault goes through this one
// gate: learn the rider's normal first (10 rides, a new rider hears nothing) · repeat on 3 rides / charges (F2 / F3 own counts) ·
// beyond the rider's worst normal + 10 % · ride ruled out (cold, heat, hills, wind, low battery, weak GPS, phone Bluetooth) = no
// verdict · below the bar = silent "watching" · "Checked, it's fine" raises the bar, twice = quiet · same finding not again for
// 2 weeks unless worse · at most 1 fault per ride summary. Normals are kept per scooter ID (A31); a firmware change relearns
// (A29); "I replaced a part" resets that part's faults (A30). Pure logic: storage is in the App layer.

/// The part a fault belongs to (Maintenance screen rows / Scooter tab tiles, N10-13 / N10-21)
public enum MaintPart: String, CaseIterable, Codable, Sendable {
    case battery, brakes, tyres, motor, bolts, electrics

    public var title: String {
        switch self {
        case .battery: return "Battery"
        case .brakes: return "Brakes"
        case .tyres: return "Tyres"
        case .motor: return "Motor"
        case .bolts: return "Bolts"
        case .electrics: return "Electrics"
        }
    }
}

/// How the rider is told (N10-12): amber = check soon, red = not safe to keep riding, info = grey card with one OK
public enum FaultLevel: Int, Codable, Comparable, Sendable {
    case info = 0, amber = 1, red = 2
    public static func < (a: FaultLevel, b: FaultLevel) -> Bool { a.rawValue < b.rawValue }
}

/// The accepted faults (F4, F8, F9, F10, F13, F14, F15 dropped)
public enum FaultKind: String, CaseIterable, Codable, Sendable {
    case f1Sag, f2PowerCut, f3BrakeCut, f5Tyre, f6Heat, f7Sensor, f11ParkedDrain, f12FullVoltage, f16OdoReset

    public var code: String {
        switch self {
        case .f1Sag: return "F1"
        case .f2PowerCut: return "F2"
        case .f3BrakeCut: return "F3"
        case .f5Tyre: return "F5"
        case .f6Heat: return "F6"
        case .f7Sensor: return "F7"
        case .f11ParkedDrain: return "F11"
        case .f12FullVoltage: return "F12"
        case .f16OdoReset: return "F16"
        }
    }

    public var part: MaintPart {
        switch self {
        case .f1Sag, .f11ParkedDrain, .f12FullVoltage: return .battery
        case .f2PowerCut, .f7Sensor, .f16OdoReset: return .electrics
        case .f3BrakeCut: return .brakes
        case .f5Tyre: return .tyres
        case .f6Heat: return .motor
        }
    }

    public var level: FaultLevel {
        switch self {
        case .f2PowerCut, .f3BrakeCut: return .red
        case .f16OdoReset: return .info
        default: return .amber
        }
    }

    /// Rides (or charges / parks) in a row beyond the bar before the rider is told
    public var repeatsNeeded: Int {
        switch self {
        case .f2PowerCut, .f3BrakeCut, .f16OdoReset: return 1   // F2 / F3: 1st time → summary; F16 is a plain fact
        default: return 3
        }
    }

    /// Whether a bigger value is worse (F12 is a voltage that drops)
    public var higherIsWorse: Bool { self != .f12FullVoltage }

    /// Told at switch-on (pop-up over Home, or a notification when the app is closed) rather than after a ride
    public var atSwitchOn: Bool { self == .f11ParkedDrain || self == .f12FullVoltage }

    /// The value is an absolute level (a voltage), so the 10 % goes on the fault's own step, not on the value
    public var absoluteScale: Bool { self == .f12FullVoltage }

    /// F16 is a fact, not a pattern: no learning, no bar
    public var needsLearning: Bool { self != .f16OdoReset }
}

/// What the gate says about one ride's (or charge's / park's) value
public enum FaultVerdict: Equatable, Sendable {
    /// Still learning the rider's normal (fewer than 10 rides): silent
    case learning
    /// Within the rider's normal: silent
    case normal
    /// Beyond the bar but not repeated enough yet, or shown in the last 2 weeks and not worse: silent "watching"
    case watching
    /// Tell the rider
    case alert(value: Double)
    /// "Checked, it's fine" twice: this fault stays quiet until a part is replaced or the firmware changes
    case quiet
    /// The ride was ruled out (cold, heat, hills, wind, low battery, weak GPS, phone Bluetooth): nothing learned, nothing said
    case ruledOut
}

/// The rider's normal for one fault on one scooter
public struct FaultBaseline: Codable, Equatable, Sendable {
    /// Values from normal rides (latest last, capped at `FaultGate.keep`)
    public var samples: [Double] = []
    /// Raised by "Checked, it's fine": nothing at or below this counts (higher-is-worse; mirrored for F12)
    public var barFloor: Double?
    public var checkedFine: Int = 0
    /// Rides in a row beyond the bar
    public var inARow: Int = 0
    /// Day number (days since 1970, UTC) and value of the last alert: never a time of day
    public var lastAlertDay: Int?
    public var lastAlertValue: Double?

    public init() {}

    public var quiet: Bool { checkedFine >= FaultGate.checkedFineForQuiet }
    public var learned: Bool { samples.count >= FaultGate.learnRides }
}

public enum FaultGate {
    /// Normal rides before the gate speaks (a new rider = silence)
    public static let learnRides = 10
    /// Normal values kept
    public static let keep = 50
    /// Beyond the rider's worst normal + 10 % (the safety margin on anything the app acts on)
    public static let margin = 0.10
    /// The same finding is not shown again for 2 weeks unless worse
    public static let repeatDays = 14
    /// "Checked, it's fine" this many times → quiet
    public static let checkedFineForQuiet = 2

    /// The bar a value must pass. nil while learning. `minGap` is a fault's own smallest step over the worst normal
    /// (e.g. F5 3 %, F6 10 °C, F12 0.5 V), so a tiny spread can't make a hair-trigger.
    public static func bar(_ b: FaultBaseline, kind: FaultKind, minGap: Double = 0) -> Double? {
        guard b.learned else { return nil }
        let worst = kind.higherIsWorse ? (b.samples.max() ?? 0) : (b.samples.min() ?? 0)
        // F12 is an absolute voltage: 10 % of 53 V would never trigger, so its margin is 10 % on top of its own step (0.5 V)
        let gap = kind.absoluteScale ? minGap * (1 + margin) : max(abs(worst) * margin, minGap)
        var bar = kind.higherIsWorse ? worst + gap : worst - gap
        if let floor = b.barFloor { bar = kind.higherIsWorse ? max(bar, floor) : min(bar, floor) }
        return bar
    }

    static func beyond(_ value: Double, _ bar: Double, _ kind: FaultKind) -> Bool {
        kind.higherIsWorse ? value > bar : value < bar
    }

    /// One ride's value through the gate. Returns the verdict and the updated baseline.
    public static func evaluate(_ base: FaultBaseline, kind: FaultKind, value: Double, ruledOut: Bool = false, minGap: Double = 0,
                                day: Int) -> (FaultVerdict, FaultBaseline) {
        var b = base
        if ruledOut { return (.ruledOut, b) }
        if !kind.needsLearning {
            return alertOrWatch(b, kind: kind, value: value, day: day)
        }
        if b.quiet { return (.quiet, b) }
        guard let bar = bar(b, kind: kind, minGap: minGap) else {
            b.samples.append(value)
            if b.samples.count > keep { b.samples.removeFirst(b.samples.count - keep) }
            return (.learning, b)
        }
        guard beyond(value, bar, kind) else {
            b.inARow = 0
            b.samples.append(value)
            if b.samples.count > keep { b.samples.removeFirst(b.samples.count - keep) }
            return (.normal, b)
        }
        // beyond the bar: never learned as normal
        b.inARow += 1
        guard b.inARow >= kind.repeatsNeeded else { return (.watching, b) }
        return alertOrWatch(b, kind: kind, value: value, day: day)
    }

    static func alertOrWatch(_ base: FaultBaseline, kind: FaultKind, value: Double, day: Int) -> (FaultVerdict, FaultBaseline) {
        var b = base
        if let last = b.lastAlertDay, day - last < repeatDays {
            let worse: Bool = {
                guard let lv = b.lastAlertValue else { return false }
                let step = max(abs(lv) * margin, 1e-9)
                return kind.higherIsWorse ? value >= lv + step : value <= lv - step
            }()
            if !worse { return (.watching, b) }
        }
        b.lastAlertDay = day
        b.lastAlertValue = value
        return (.alert(value: value), b)
    }

    /// "Checked, it's fine": the bar moves past this finding (+10 %); the second time the fault goes quiet
    public static func checkedFine(_ base: FaultBaseline, kind: FaultKind) -> FaultBaseline {
        var b = base
        b.checkedFine += 1
        b.inARow = 0
        if let v = b.lastAlertValue {
            let step = kind.absoluteScale ? 0.05 : abs(v) * margin     // F12: 0.05 V past the finding
            let raised = kind.higherIsWorse ? v + step : v - step
            if let f = b.barFloor { b.barFloor = kind.higherIsWorse ? max(f, raised) : min(f, raised) } else { b.barFloor = raised }
        }
        return b
    }

    /// Day number (days since 1970, UTC) for the 2-week rule; never a time of day
    public static func day(epochMs: Int64) -> Int { Int(epochMs / 86_400_000) }
}

/// One finding the gate let through
public struct FaultFinding: Equatable, Sendable {
    public var kind: FaultKind
    public var value: Double
    /// How far past the bar, as a share of the bar (for picking the one to show)
    public var excess: Double

    public init(kind: FaultKind, value: Double, excess: Double) {
        self.kind = kind
        self.value = value
        self.excess = excess
    }

    /// At most 1 fault per ride summary: red before amber before info, then the one furthest past its bar
    public static func pickOne(_ findings: [FaultFinding]) -> FaultFinding? {
        findings.max { a, b in
            if a.kind.level != b.kind.level { return a.kind.level < b.kind.level }
            return a.excess < b.excess
        }
    }
}

/// All baselines, keyed per scooter ID and fault (A31)
public struct FaultBook: Codable, Equatable, Sendable {
    public var baselines: [String: FaultBaseline] = [:]
    /// Firmware version seen per scooter (A29)
    public var firmware: [String: String] = [:]

    public init() {}

    public static func key(_ scooterId: String, _ kind: FaultKind) -> String { scooterId + "|" + kind.rawValue }

    public func baseline(_ scooterId: String, _ kind: FaultKind) -> FaultBaseline {
        baselines[Self.key(scooterId, kind)] ?? FaultBaseline()
    }

    public mutating func set(_ b: FaultBaseline, _ scooterId: String, _ kind: FaultKind) {
        baselines[Self.key(scooterId, kind)] = b
    }

    /// A31 / A29: a new firmware version on this scooter → every fault relearns. Returns true when it reset.
    @discardableResult
    public mutating func noteFirmware(_ version: String, scooterId: String) -> Bool {
        defer { firmware[scooterId] = version }
        guard let old = firmware[scooterId], old != version else { return false }
        for kind in FaultKind.allCases { baselines[Self.key(scooterId, kind)] = nil }
        return true
    }

    /// A30: "I replaced a part" resets the faults of that part
    public mutating func partReplaced(_ part: MaintPart, scooterId: String) {
        for kind in FaultKind.allCases where kind.part == part { baselines[Self.key(scooterId, kind)] = nil }
    }
}
