import Foundation

/// F-31b (owner 21 Oct, FINAL): Plug in after every ride. Home shows one big "⚡ Plug in" pill (one tap = the timer starts from the
/// last reading, no form) and a small pill with the alert choice ("100%" / "15 km"). The small pill opens a sheet with only Battery |
/// Range, a big number with − and +, and one line "18:02 estimated" (tap "estimated" for why). Default 100 %, remembered.
/// It shows after any ride, never during one, and goes at the next connect, the next ride, or after 2 h. Pure, tested on Linux.

/// What to be told while charging
public enum PlugAlert: Codable, Equatable, Sendable {
    /// at this battery % (100 = full)
    case battery(Int)
    /// when the battery holds this many km
    case range(Int)

    public static let `default` = PlugAlert.battery(100)

    public var isRange: Bool { if case .range = self { return true } else { return false } }

    /// The big number in the sheet
    public var number: Int {
        switch self { case .battery(let p): return p; case .range(let km): return km }
    }

    /// The small pill: "100%" / "15 km"
    public var pillText: String {
        switch self { case .battery(let p): return "\(p)%"; case .range(let km): return "\(km) km" }
    }
}

public enum PlugIn {
    /// The pill goes this long after the ride ended
    public static let showForMs: Int64 = 2 * 3_600_000
    /// − / + steps
    public static let pctStep = 5
    public static let kmStep = 1
    public static let pctRange = 5...100
    public static let kmRange = 1...150
    /// Range starts here the first time
    public static let defaultKm = 15

    /// Home shows the Plug in pill: a ride ended within 2 h, no ride now, not charging, the scooter not connected and no connect since
    /// the ride ended.
    public static func shows(rideEndMs: Int64?, nowMs: Int64, riding: Bool, charging: Bool, connected: Bool, lastConnectMs: Int64?) -> Bool {
        guard let end = rideEndMs, !riding, !charging, !connected else { return false }
        guard nowMs >= end, nowMs - end <= showForMs else { return false }
        if let c = lastConnectMs, c > end { return false }
        return true
    }

    /// − (by −1) or + (by +1), clamped
    public static func stepped(_ a: PlugAlert, by direction: Int) -> PlugAlert {
        switch a {
        case .battery(let p): return .battery(clamp(p + direction * pctStep, pctRange))
        case .range(let km): return .range(clamp(km + direction * kmStep, kmRange))
        }
    }

    /// A typed number, clamped (nil when it is not a number)
    public static func typed(_ text: String, for a: PlugAlert) -> PlugAlert? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        switch a {
        case .battery: return .battery(clamp(n, pctRange))
        case .range: return .range(clamp(n, kmRange))
        }
    }

    /// Battery | Range switch: keeps the other side's last number
    public static func switched(_ a: PlugAlert, toRange: Bool, lastPct: Int = 100, lastKm: Int = defaultKm) -> PlugAlert {
        toRange ? (a.isRange ? a : .range(clamp(lastKm, kmRange))) : (a.isRange ? .battery(clamp(lastPct, pctRange)) : a)
    }

    static func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(r.upperBound, max(r.lowerBound, v)) }

    /// The timer's target: 100 % is the "full" notification itself (no second one)
    public static func target(_ a: PlugAlert) -> ChargeTarget {
        switch a {
        case .battery(let p): return p >= 100 ? .none : .pct(p)
        case .range(let km): return .km(Double(km))
        }
    }

    /// When the alert comes, epoch ms. 100 % includes the +5 % margin (P-1); a km alert includes the rider's %/km +10 % and the
    /// reserve. nil: a km alert before the rider's %/km is known.
    public static func alertMs(_ s: ChargeSession, _ a: PlugAlert) -> Int64? {
        switch a {
        case .battery(let p): return p >= 100 ? ChargeModel.notifyFullMs(s) : ChargeModel.timeMs(toPct: Double(p), s)
        case .range(let km):
            guard let p = ChargeModel.pctForKm(Double(km), pctPerKm: s.pctPerKm, reservePct: s.reservePct) else { return nil }
            return ChargeModel.timeMs(toPct: Double(p), s)
        }
    }

    /// The clock part of "18:02 estimated" (the sheet underlines the word "estimated" and puts it after); nil = not known yet
    public static func alertClock(_ s: ChargeSession, _ a: PlugAlert, utcOffsetMin: Int) -> String? {
        alertMs(s, a).map { ChargeText.clock($0, utcOffsetMin: utcOffsetMin) }
    }

    /// When the clock is not known yet
    public static let needsRidesText = "Needs a few rides first: your battery per km is not known yet."

    /// Tap "estimated": how the time is worked out, in plain words
    public static func why(_ s: ChargeSession, _ a: PlugAlert, utcOffsetMin: Int) -> String {
        var parts = ["It charges about \(fmt(ChargeModel.ratePctPerHour)) % an hour (measured on this charger).",
                     "Started at \(Int(s.startPct.rounded()))% at \(ChargeText.clock(s.startMs, utcOffsetMin: utcOffsetMin)), the last reading."]
        switch a {
        case .battery(let p) where p >= 100:
            parts.append("For full it waits 5 % longer, so the battery really is full.")
        case .battery:
            break
        case .range(let km):
            if let rate = s.pctPerKm, let p = ChargeModel.pctForKm(Double(km), pctPerKm: rate, reservePct: s.reservePct) {
                parts.append("\(km) km uses your \(fmt(rate)) % per km, +10 % margin and a \(Int(s.reservePct.rounded())) % reserve: about \(p)%.")
            } else {
                parts.append(needsRidesText)
            }
        }
        parts.append("The real reading corrects it on the next connect.")
        return parts.joined(separator: " ")
    }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }

    /// The charge line's alert part: "Alert 18:02" (nil when not known)
    public static func chargeLineAlert(_ s: ChargeSession, _ a: PlugAlert, utcOffsetMin: Int) -> String? {
        alertClock(s, a, utcOffsetMin: utcOffsetMin).map { "\(a.pillText) \u{2248} \($0)" }
    }
}
