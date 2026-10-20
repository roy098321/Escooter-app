import Foundation

// F-31 · time to full charge. The model is the owner's measured straight line (calibration audit, charge side): 13.6 %/h, no
// slowdown above 80 %. Shown numbers are honest 100 % estimates and always "≈" (P-1); the margins live only in what the app acts on:
// the "full" notification (100 % + 5 %), the km target (the rider's %/km +10 % + the reserve) and "enough for Work and back".

/// What the owner asked to be told, besides "full".
public enum ChargeTarget: Codable, Equatable, Sendable {
    case none
    /// Battery % (80 / 90 / custom)
    case pct(Int)
    /// Range in km the battery should hold
    case km(Double)
    /// A clock time (epoch ms, already resolved to the next occurrence)
    case readyBy(atMs: Int64)
}

/// One charging timer: the plug-in moment and the % then (the last reading, or the corrected start %).
public struct ChargeSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startPct: Double
    public var startMs: Int64
    public var target: ChargeTarget
    /// The rider's blended battery % per km (nil: unknown, so a km target cannot be turned into a %)
    public var pctPerKm: Double?
    public var reservePct: Double
    /// The usual battery need of the usual trip, % (for "enough for Work and back"), and its name
    public var usualNeedPct: Double?
    public var usualName: String?
    /// The scooter's name for the texts
    public var scooterName: String

    public init(id: String = UUID().uuidString, startPct: Double, startMs: Int64, target: ChargeTarget = .none, pctPerKm: Double? = nil,
                reservePct: Double = T.t80ReserveDefaultPct, usualNeedPct: Double? = nil, usualName: String? = nil, scooterName: String = "Scooter") {
        self.id = id
        self.startPct = startPct
        self.startMs = startMs
        self.target = target
        self.pctPerKm = pctPerKm
        self.reservePct = reservePct
        self.usualNeedPct = usualNeedPct
        self.usualName = usualName
        self.scooterName = scooterName
    }
}

public enum ChargeModel {
    /// Measured 19-20 Oct 2026: 94 points in 415 minutes
    public static let ratePctPerHour = 13.6
    /// The "full" notification waits for 100 % + this (P-1: the app acts on it)
    public static let fullNotifyMarginPct = 5.0
    /// The one tick on the bar
    public static let tickPct = 80

    public static let msPerHour = 3_600_000.0

    /// ≈ % at a moment (never above 100, never below the start)
    public static func pct(_ s: ChargeSession, atMs: Int64) -> Double {
        let hours = max(0, Double(atMs - s.startMs) / msPerHour)
        return min(100, max(s.startPct, s.startPct + hours * ratePctPerHour))
    }

    /// When the line reaches `target` %, epoch ms (the start itself if already there)
    public static func timeMs(toPct target: Double, _ s: ChargeSession) -> Int64 {
        let need = max(0, target - s.startPct)
        return s.startMs + Int64((need / ratePctPerHour * msPerHour).rounded())
    }

    /// The honest 100 % estimate ("Full ≈")
    public static func fullMs(_ s: ChargeSession) -> Int64 { timeMs(toPct: 100, s) }

    /// When the "full" notification fires: (100 − start + 5) ÷ 13.6 h after the plug-in
    public static func notifyFullMs(_ s: ChargeSession) -> Int64 { timeMs(toPct: 100 + fullNotifyMarginPct, s) }

    public static func isFull(_ s: ChargeSession, atMs: Int64) -> Bool { atMs >= fullMs(s) }

    /// Whole minutes to 100 % (0 once full)
    public static func minutesLeft(_ s: ChargeSession, atMs: Int64) -> Int {
        max(0, Int((Double(fullMs(s) - atMs) / 60_000).rounded(.up)))
    }

    /// Progress 0...1 on the bar (start % → 100 %)
    public static func progress(_ s: ChargeSession, atMs: Int64) -> Double { pct(s, atMs: atMs) / 100 }

    /// km → the % the battery needs: km × the rider's %/km +10 % (P-1) + the reserve, rounded up, at most 100. nil without a %/km.
    public static func pctForKm(_ km: Double, pctPerKm: Double?, reservePct: Double = T.t80ReserveDefaultPct) -> Int? {
        guard let rate = pctPerKm, rate > 0, km > 0 else { return nil }
        let need = SafetyMargin.forDecision(km * rate) + reservePct
        return min(100, Int((need - 1e-9).rounded(.up)))
    }

    /// The % a target is waiting for (nil for none, ready-by and an unusable km)
    public static func targetPct(_ s: ChargeSession) -> Int? {
        switch s.target {
        case .pct(let p): return min(100, max(1, p))
        case .km(let km): return pctForKm(km, pctPerKm: s.pctPerKm, reservePct: s.reservePct)
        case .none, .readyBy: return nil
        }
    }

    /// When the target is reached, epoch ms (ready-by: the clock time itself)
    public static func targetMs(_ s: ChargeSession) -> Int64? {
        if case .readyBy(let at) = s.target { return at }
        return targetPct(s).map { timeMs(toPct: Double($0), s) }
    }

    /// "Ready by": the ≈ % at that time, and whether it covers the usual trip (usual need +10 % + reserve). nil enough = no usual trip.
    public static func readyBy(_ s: ChargeSession, atMs: Int64) -> (pct: Int, isFull: Bool, enough: Bool?) {
        let p = pct(s, atMs: atMs)
        let full = p >= 100
        var enough: Bool?
        if let need = s.usualNeedPct { enough = p >= SafetyMargin.forDecision(need) + s.reservePct }
        return (min(100, Int(p.rounded())), full, enough)
    }

    /// The next time the clock shows `minuteOfDay` after `afterMs` (local time = UTC + `utcOffsetMin`)
    public static func nextOccurrence(minuteOfDay: Int, afterMs: Int64, utcOffsetMin: Int) -> Int64 {
        let dayMs: Int64 = 86_400_000
        let local = afterMs + Int64(utcOffsetMin) * 60_000
        var day = local - ((local % dayMs) + dayMs) % dayMs
        var at = day + Int64(minuteOfDay) * 60_000
        while at <= local { day += dayMs; at = day + Int64(minuteOfDay) * 60_000 }
        return at - Int64(utcOffsetMin) * 60_000
    }
}

/// The words (all "≈"; clocks are 24 h).
public enum ChargeText {
    public static func clock(_ ms: Int64, utcOffsetMin: Int) -> String {
        let minute = Int(((Double(ms) / 60_000) + Double(utcOffsetMin)).rounded())
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// "2 h 05 min", "45 min"
    public static func duration(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        return String(format: "%d h %02d min", m / 60, m % 60)
    }

    public static func pctText(_ p: Double) -> String { "\u{2248} \(Int(p.rounded())) %" }

    public static func fullLine(_ s: ChargeSession, utcOffsetMin: Int) -> String { "Full \u{2248} \(clock(ChargeModel.fullMs(s), utcOffsetMin: utcOffsetMin))" }

    /// "Full ≈ 01:02 · we'll notify you at ≈ 01:24"
    public static func sheetFullLine(_ s: ChargeSession, utcOffsetMin: Int) -> String {
        "\(fullLine(s, utcOffsetMin: utcOffsetMin)) \u{00B7} \u{201C}\(s.scooterName) is full\u{201D} at \u{2248} \(clock(ChargeModel.notifyFullMs(s), utcOffsetMin: utcOffsetMin)) (+5 % margin)"
    }

    /// "80 % ≈ 23:34 · 100 % ≈ 01:02"
    public static func ticksLine(_ s: ChargeSession, utcOffsetMin: Int) -> String {
        let t = ChargeModel.tickPct
        return "\(t) % \u{2248} \(clock(ChargeModel.timeMs(toPct: Double(t), s), utcOffsetMin: utcOffsetMin)) \u{00B7} 100 % \u{2248} \(clock(ChargeModel.fullMs(s), utcOffsetMin: utcOffsetMin))"
    }

    /// "10 km ≈ 31 % · ≈ 19:57" (nil without a %/km)
    public static func kmLine(_ s: ChargeSession, km: Double, utcOffsetMin: Int) -> String? {
        guard let p = ChargeModel.pctForKm(km, pctPerKm: s.pctPerKm, reservePct: s.reservePct) else { return nil }
        let at = ChargeModel.timeMs(toPct: Double(p), s)
        return "\(kmText(km)) \u{2248} \(p) % \u{00B7} \u{2248} \(clock(at, utcOffsetMin: utcOffsetMin))"
    }

    public static func kmText(_ km: Double) -> String { km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km) }

    /// The ready-by answer for the sheet
    public static func readyByLine(_ s: ChargeSession, atMs: Int64, utcOffsetMin: Int) -> String {
        let r = ChargeModel.readyBy(s, atMs: atMs)
        let c = clock(atMs, utcOffsetMin: utcOffsetMin)
        var line = r.isFull ? "\u{2248} 100 % by then" : "\u{2248} \(r.pct) % by \(c)"
        if let usual = s.usualName, let enough = r.enough {
            line += enough ? ", enough for \(usual) and back" : ", not enough for \(usual) and back"
        }
        return line
    }

    public static func fullNotification(_ s: ChargeSession) -> (title: String, body: String) { ("\(s.scooterName) is full.", "Unplug when convenient.") }

    public static func targetNotification(_ s: ChargeSession, utcOffsetMin: Int) -> (title: String, body: String)? {
        switch s.target {
        case .none: return nil
        case .pct(let p): return ("\(s.scooterName) is at \(p) %.", "\u{2248} \(p) % now.")
        case .km(let km):
            guard let p = ChargeModel.targetPct(s) else { return nil }
            return ("\(s.scooterName) has enough for \(kmText(km)) (\u{2248} \(p) %).", "Unplug when convenient.")
        case .readyBy(let at):
            return ("\(s.scooterName) is ready.", readyByLine(s, atMs: at, utcOffsetMin: utcOffsetMin))
        }
    }
}

/// The local notifications of one session (scheduled at these times; rescheduled on every edit).
public struct ChargeNote: Equatable, Sendable {
    public var id: String
    public var atMs: Int64
    public var title: String
    public var body: String
}

public enum ChargeNotifications {
    public static let fullId = "charge.full"
    public static let targetId = "charge.target"
    public static var allIds: [String] { [fullId, targetId] }

    /// Only the notes still in the future at `nowMs`. A ready-by note is skipped when the battery is full by then (the full note covers it).
    public static func plan(_ s: ChargeSession, nowMs: Int64, utcOffsetMin: Int) -> [ChargeNote] {
        var out: [ChargeNote] = []
        let full = ChargeText.fullNotification(s)
        out.append(ChargeNote(id: fullId, atMs: ChargeModel.notifyFullMs(s), title: full.title, body: full.body))
        if let at = ChargeModel.targetMs(s), let t = ChargeText.targetNotification(s, utcOffsetMin: utcOffsetMin) {
            var skip = false
            if case .readyBy = s.target, ChargeModel.readyBy(s, atMs: at).isFull { skip = true }
            if !skip { out.append(ChargeNote(id: targetId, atMs: at, title: t.title, body: t.body)) }
        }
        return out.filter { $0.atMs > nowMs }
    }
}

/// How a finished charge is logged (F-27): measured = the real % was read on the next connect; estimated = the owner tapped Unplugged.
public struct ChargeLogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startMs: Int64
    public var endMs: Int64
    public var startPct: Double
    public var endPct: Double
    /// true: the end % is a real reading; false: the line's ≈
    public var measured: Bool

    public init(id: String, startMs: Int64, endMs: Int64, startPct: Double, endPct: Double, measured: Bool) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.startPct = startPct
        self.endPct = endPct
        self.measured = measured
    }

    public var gainedPct: Double { max(0, endPct - startPct) }

    /// Ends a session: at `atMs` with a real reading (measured) or on the line (≈).
    public static func finish(_ s: ChargeSession, atMs: Int64, realPct: Double?) -> ChargeLogEntry {
        let end = realPct ?? ChargeModel.pct(s, atMs: atMs)
        return ChargeLogEntry(id: s.id, startMs: s.startMs, endMs: max(s.startMs, atMs), startPct: s.startPct, endPct: end, measured: realPct != nil)
    }
}
