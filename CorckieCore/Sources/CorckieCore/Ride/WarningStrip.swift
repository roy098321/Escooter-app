import Foundation

/// N8-1 / N8-3 (batch 8, owner 17 Nov): the warning-light strip at the top of the live screen. Small car-style icons, ICONS ONLY while
/// riding, shown only when something is wrong (nothing when all is fine). Colour = seriousness (ISO 2575 style): red / amber / blue.
/// At most 3 at once, ranked by the owner's order; red always first; lower ones wait for a free slot; ones never shown go to the ride
/// summary. At a stop (WHEEL speed 0 for 1 s, never GPS speed) an icon can expand sideways into one line; while moving a tap does
/// nothing; with no wheel speed (disconnected) nothing expands. Each light has a level (N8-3): L3 icon + voice + vibration (as today),
/// L2 icon + one soft low tone once per ride, L1 icon only.
public enum WarningLight: Int, CaseIterable, Comparable, Sendable {
    // owner order 1...12
    case motorVeryHot = 1, powerLimitSoon, disconnected, motorHot, phoneBatteryLow, recordingProblem, noGps,
         rainSoon, darkBeforeArrival, phoneTookOver, offlineMap, gearReminder

    public enum Colour: Sendable { case red, amber, blue }

    public var colour: Colour {
        switch self {
        case .motorVeryHot: return .red
        case .powerLimitSoon, .disconnected, .motorHot, .phoneBatteryLow, .recordingProblem, .noGps: return .amber
        case .rainSoon, .darkBeforeArrival, .phoneTookOver, .offlineMap, .gearReminder: return .blue
        }
    }

    /// N8-3: 3 = icon + voice + vibration (today's), 2 = icon + one soft tone once per ride, 1 = icon only
    public var level: Int {
        switch self {
        case .motorVeryHot, .motorHot, .powerLimitSoon: return 3
        case .disconnected, .phoneBatteryLow, .recordingProblem, .noGps: return 2
        case .rainSoon, .darkBeforeArrival, .phoneTookOver, .offlineMap, .gearReminder: return 1
        }
    }

    public var symbol: String {
        switch self {
        case .motorVeryHot, .motorHot: return "thermometer.high"
        case .powerLimitSoon: return "bolt.badge.clock"
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .phoneBatteryLow: return "battery.25percent"
        case .recordingProblem: return "record.circle"
        case .noGps: return "location.slash"
        case .rainSoon: return "cloud.rain"
        case .darkBeforeArrival: return "moon"
        case .phoneTookOver: return "iphone"
        case .offlineMap: return "map"
        case .gearReminder: return "gauge.with.dots.needle.67percent"
        }
    }

    /// The one line it expands into at a stop
    public var line: String {
        switch self {
        case .motorVeryHot: return "Motor very hot"
        case .powerLimitSoon: return "Power limit soon"
        case .disconnected: return "Scooter disconnected \u{00B7} reconnecting"
        case .motorHot: return "Motor hot"
        case .phoneBatteryLow: return "Phone battery low \u{00B7} map paused"
        case .recordingProblem: return "Recording problem"
        case .noGps: return "No GPS"
        case .rainSoon: return "Rain within 20 min"
        case .darkBeforeArrival: return "Dark before you arrive"
        case .phoneTookOver: return "Phone took over the speed reading"
        case .offlineMap: return "Offline map"
        case .gearReminder: return "Capped by the gear"
        }
    }

    public static func < (a: WarningLight, b: WarningLight) -> Bool { a.rawValue < b.rawValue }
}

public struct WarningStrip: Equatable, Sendable {
    public static let maxShown = 3
    /// "At a stop": wheel speed 0 for this long
    public static let stopHoldS = 1.0

    /// The lights shown now (ranked, red first, at most 3)
    public private(set) var shown: [WarningLight] = []
    /// Lights that were on during the ride but never got a slot: the ride summary lists them
    public private(set) var neverShown: Set<WarningLight> = []
    private var everShown: Set<WarningLight> = []
    private var stoppedSince: Double?
    /// L2 lights that already played their tone this ride
    private var toned: Set<WarningLight> = []

    public init() {}

    /// One update with the lights that are on now. Returns the L2 lights that should play the soft tone now (once per ride each).
    @discardableResult
    public mutating func update(on: Set<WarningLight>, wheelSpeedKmh: Double?, at t: Double) -> [WarningLight] {
        let ranked = on.sorted()     // red is rank 1, so it is always first
        shown = Array(ranked.prefix(Self.maxShown))
        everShown.formUnion(shown)
        for w in ranked.dropFirst(Self.maxShown) where !everShown.contains(w) { neverShown.insert(w) }
        neverShown.subtract(everShown)
        if let v = wheelSpeedKmh, v <= 0 { if stoppedSince == nil { stoppedSince = t } } else { stoppedSince = nil }
        let tones = shown.filter { $0.level == 2 && !toned.contains($0) }
        toned.formUnion(tones)
        return tones
    }

    /// N8-1: an icon may expand into its line only at a stop: WHEEL speed 0 for 1 s (never GPS speed; no wheel speed, no expand)
    public func canExpand(at t: Double) -> Bool {
        guard let s = stoppedSince else { return false }
        return t - s >= Self.stopHoldS
    }

    public mutating func rideEnded() { self = WarningStrip() }
}
