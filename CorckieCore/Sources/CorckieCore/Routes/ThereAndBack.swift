import Foundation

/// M2-09 (CALC_SPEC M27, Q9): can the battery do the round trip? `needed = (today(A to B) + today(B to A at the usual return time))
/// x 1.10 + reserve` (the margin is already in each leg's `neededPct`, T101 / G2); spare = battery now - needed. The logic is
/// `RouteFit.evaluate` (the same one that greys the Routes list); this adds the card text and the ride-start warning.
/// Decisions use `neededPct`, the texts show the honest `usedPct`.
public struct ThereAndBackModel: Equatable, Sendable {
    public var status: RouteFitStatus
    /// "\u{2705}", "\u{26A0}" or "\u{274C}"
    public var symbol: String
    public var headline: String
    public var detail: String
    public var sparePct: Double?
    /// "Home" or "Work": where the way there ends (for the ride-start warning)
    public var destination: String
    public var batteryPct: Double
}

public enum ThereAndBack {
    /// nil = nothing to say (no battery reading, or not enough rides on a leg that has to be judged: gate of 5 rides, T67)
    public static func model(there: TodayResult, back: TodayResult, battery: BatteryNow?, canChargeAtEnd: Bool, destination: String,
                             reservePct: Double = T.t80ReserveDefaultPct) -> ThereAndBackModel? {
        guard case .estimate(let t) = there, let battery = battery else { return nil }
        var backEstimate: TodayEstimate?
        if case .estimate(let b) = back { backEstimate = b }
        let fit = RouteFit.evaluate(thereNeededPct: t.neededPct, thereUsedPct: t.usedPct, backNeededPct: backEstimate?.neededPct, battery: battery,
                                    canChargeAtEnd: canChargeAtEnd, reservePct: reservePct)
        guard fit.status != .noData else { return nil }

        var legs: [String] = []
        if let u = t.usedPct { legs.append("there about \(Int(u.rounded()))%") }
        if !canChargeAtEnd, let u = backEstimate?.usedPct { legs.append("back about \(Int(u.rounded()))%") }
        let tail = legs.isEmpty ? "" : " \u{00B7} " + legs.joined(separator: ", ")
        let basis = "a 10% margin and a \(Int(reservePct.rounded()))% reserve are counted"
        let spare = fit.sparePct.map { Int(max(0, $0).rounded(.down)) }
        let symbol: String
        let headline: String
        var detail = "Battery \(battery.text)\(tail) \u{00B7} \(basis)"
        switch fit.status {
        case .fits:
            symbol = "\u{2705}"
            headline = canChargeAtEnd ? "\(symbol) Enough to get there" : "\(symbol) There and back fits"
            if let s = spare { detail += " \u{00B7} about \(s)% to spare" }
            if canChargeAtEnd { detail += " \u{00B7} you can charge at the end" }
        case .tight:
            symbol = "\u{26A0}"
            headline = canChargeAtEnd ? "\(symbol) Barely enough to get there" : "\(symbol) Barely enough for a round trip"
        case .oneWayOnly:
            symbol = "\u{274C}"
            headline = "\(symbol) Not enough for the way back"
        default:
            symbol = "\u{274C}"
            headline = "\(symbol) Not enough battery for the way there"
        }
        return ThereAndBackModel(status: fit.status, symbol: symbol, headline: headline, detail: detail, sparePct: fit.sparePct,
                                 destination: destination, batteryPct: battery.pct)
    }

    /// Q9 at ride start (the destination is known): one line when the way back will not fit, is tight, or even the way there does not.
    /// nil when it fits (nothing is said).
    public static func startWarning(_ m: ThereAndBackModel) -> String? {
        let p = Int(m.batteryPct.rounded())
        switch m.status {
        case .oneWayOnly: return "Battery \(p)%: enough for \(m.destination), not for the way back."
        case .tight: return "Battery \(p)%: just enough for \(m.destination) and back."
        case .notEnough: return "Battery \(p)%: may not reach \(m.destination)."
        default: return nil
        }
    }
}
