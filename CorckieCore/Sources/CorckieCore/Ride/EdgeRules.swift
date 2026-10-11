import Foundation

// M6-06 (C28 edge cases): the rules, pure and unit tested; the app (PhoneSensors, Home, RecorderService) only applies them.

/// What the phone's GPS does at a given phone battery (C28: below 20% less often, below 10% off with one banner).
public enum PhoneGps: String, Equatable, Sendable {
    case normal, reduced, off
}

public enum PhoneBatteryPolicy {
    public static let reducedBelowPct = 20
    public static let offBelowPct = 10
    /// Reduced mode: a fix only after this many metres, at 10 m accuracy
    public static let reducedDistanceFilterM = 15.0
    public static let bannerText = "Phone battery low \u{00B7} map paused"

    /// - pct: the phone battery 0...100, nil when unknown (then nothing changes)
    /// - charging: in the holder with a cable: full GPS
    /// - lowPowerMode: iOS Low Power Mode is on: less often, like below 20% (no banner; iOS already throttles the phone)
    public static func gps(pct: Int?, charging: Bool, lowPowerMode: Bool) -> PhoneGps {
        if charging { return .normal }
        if let p = pct {
            if p < offBelowPct { return .off }
            if p < reducedBelowPct { return .reduced }
        }
        return lowPowerMode ? .reduced : .normal
    }
}

/// Phone storage (C28: "older raw data is thinned early; a Home banner if backups can't be written").
public enum StoragePolicy {
    public enum Level: Int, Equatable, Comparable, Sendable {
        case ok = 0, thin, warn
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Below this the raw packet stream older than `thinDays` goes early
    public static let thinBelowBytes: Int64 = 1_000_000_000
    /// Below this the Home card warns (a backup or a ride may not be written)
    public static let warnBelowBytes: Int64 = 300_000_000
    public static let thinDays = 14

    public static func level(freeBytes: Int64?) -> Level {
        guard let b = freeBytes else { return .ok }
        if b < warnBelowBytes { return .warn }
        if b < thinBelowBytes { return .thin }
        return .ok
    }

    public static func homeNotice(_ level: Level, freeBytes: Int64?) -> String? {
        guard level == .warn, let b = freeBytes else { return nil }
        let mb = Int((Double(b) / 1_000_000).rounded())
        return "Phone storage almost full (\(mb) MB left). Older raw readings are thinned and backups may not be written. Free some space."
    }

    /// Cut-off (ms) for the early thinning, nil when storage is fine
    public static func thinCutoffMs(_ level: Level, nowMs: Int64) -> Int64? {
        level >= .thin ? nowMs - Int64(thinDays) * 86_400_000 : nil
    }
}

/// The 7-day re-sign (C28: a reminder 1 day before the app expires; backups mean nothing is lost).
public enum AppExpiry {
    public static let reminderBeforeMs: Int64 = 86_400_000

    public enum Plan: Equatable, Sendable {
        /// The expiry date is unknown (App Store / simulator build)
        case unknown
        /// Schedule the reminder at this time (epoch ms)
        case remind(atMs: Int64)
        /// Less than a day left and the reminder time has passed: tell on Home now
        case soon(hoursLeft: Int)
        case expired
    }

    public static func plan(expiryMs: Int64?, nowMs: Int64) -> Plan {
        guard let e = expiryMs else { return .unknown }
        if e <= nowMs { return .expired }
        let at = e - reminderBeforeMs
        if at > nowMs + 60_000 { return .remind(atMs: at) }
        return .soon(hoursLeft: max(1, Int((Double(e - nowMs) / 3_600_000).rounded(.up))))
    }

    public static func homeNotice(_ plan: Plan) -> String? {
        switch plan {
        case .soon(let h): return "CorckieApp expires in about \(h) h. Refresh it in SideStore (your rides are safe)."
        case .expired: return "CorckieApp has expired. Refresh it in SideStore. Rides while it was expired are not recorded."
        default: return nil
        }
    }

    public static let reminderTitle = "CorckieApp expires tomorrow"
    public static let reminderBody = "Refresh it in SideStore so it keeps recording. Your rides are safe."
}

/// A phone clock that is set during a ride (by hand, or the network time after a long sleep) must not move the ride:
/// the engine runs on `anchor wall time + monotonic time since`. Timestamps from the sensors (wall clock) are mapped back.
public struct ClockGuard: Equatable, Sendable {
    /// A difference above this many seconds is a clock change
    public static let jumpS = 5.0

    private var anchorWall: Double
    private var anchorMono: Double

    public init(wall: Double, mono: Double) {
        anchorWall = wall
        anchorMono = mono
    }

    /// The engine's time: equals the wall clock until the wall clock is changed
    public func now(mono: Double) -> Double { anchorWall + (mono - anchorMono) }

    /// How far the wall clock is ahead of the engine's time (+ = set forward, - = set back)
    public func offsetS(wall: Double, mono: Double) -> Double { wall - now(mono: mono) }

    public func isJump(wall: Double, mono: Double) -> Bool { abs(offsetS(wall: wall, mono: mono)) > Self.jumpS }

    /// A sensor timestamp (wall clock) on the engine's timeline
    public func engineTime(ofWall stamp: Double, wall: Double, mono: Double) -> Double { stamp - offsetS(wall: wall, mono: mono) }

    public mutating func reanchor(wall: Double, mono: Double) {
        anchorWall = wall
        anchorMono = mono
    }
}
