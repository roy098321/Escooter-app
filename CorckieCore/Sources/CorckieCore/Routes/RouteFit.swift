import Foundation

/// M2-05 (CALC_SPEC M27, owner policy G2 / T101): does the battery reach a route? Decisions use the margin-carrying
/// `neededPct` of the Today estimate (honest used % x 1.10), never the honest number; the texts show the honest number.
///
/// - One way does not fit (`neededPct + reserve > battery now`): the row is greyed, "Not enough battery", still tappable.
/// - There fits, the way back does not (M27 red for the round trip): amber "One way only".
/// - Round trip spare under 10% (T82): amber "Tight".
/// - "I can charge here" on the end place: only the way there has to fit.
/// - Battery data not enough (5 rides, T67) on a leg that has to be judged: no chip, no greying.
public struct BatteryNow: Equatable, Sendable {
    public var pct: Double
    /// nil = the scooter is connected and this is a live reading; else minutes since the scooter was last seen
    public var ageMin: Int?

    public init(pct: Double, ageMin: Int? = nil) {
        self.pct = pct
        self.ageMin = ageMin
    }

    /// "64% now" or "64% (2 h ago)"
    public var text: String {
        let p = Int(pct.rounded())
        guard let age = ageMin else { return "\(p)% now" }
        return "\(p)% (\(RouteFit.ageText(minutes: age)))"
    }
}

public enum RouteFitStatus: String, Equatable, Sendable {
    /// Not enough data, or no battery reading: nothing is said
    case noData
    case fits
    case tight
    case oneWayOnly
    case notEnough
}

public struct RouteFitResult: Equatable, Sendable {
    public var status: RouteFitStatus
    /// Battery now minus what the decision needs, in percentage points (nil without data)
    public var sparePct: Double?
    /// "Not enough battery", "One way only", "Tight", or nil
    public var chip: String?
    public var greyed: Bool
    /// One honest line under the title ("Battery 12% now . this ride uses about 11% and a 5% reserve stays")
    public var detail: String?

    public static let silent = RouteFitResult(status: .noData, sparePct: nil, chip: nil, greyed: false, detail: nil)
}

public enum RouteFit {
    public static let notEnoughText = "Not enough battery"
    public static let oneWayText = "One way only"
    public static let tightText = "Tight"

    /// - Parameters:
    ///   - thereNeededPct: `neededPct` (with the 10% margin) of Today for A to B; nil until the battery gate is met
    ///   - thereUsedPct: the honest used % of the same estimate, for the text only
    ///   - backNeededPct: `neededPct` of Today for B to A at the usual return time; nil without data
    ///   - battery: the scooter's battery now (or last seen with its age); nil = unknown
    ///   - canChargeAtEnd: "I can charge here" on B: only A to B must fit
    public static func evaluate(thereNeededPct: Double?, thereUsedPct: Double? = nil, backNeededPct: Double?, battery: BatteryNow?,
                                canChargeAtEnd: Bool = false, reservePct: Double = T.t80ReserveDefaultPct) -> RouteFitResult {
        guard let there = thereNeededPct, let battery = battery else { return .silent }
        let now = battery.pct
        let eps = 1e-9
        let oneWay = there + reservePct
        let reserveText = Int(reservePct.rounded())
        var used = ""
        if let u = thereUsedPct { used = "this ride uses about \(Int(u.rounded()))% and " }

        if oneWay > now + eps {
            return RouteFitResult(status: .notEnough, sparePct: now - oneWay, chip: notEnoughText, greyed: true,
                                  detail: "Battery \(battery.text) \u{00B7} \(used)a \(reserveText)% reserve stays")
        }
        if canChargeAtEnd {
            let spare = now - oneWay
            if spare + eps < T.t82SparePct {
                return RouteFitResult(status: .tight, sparePct: spare, chip: tightText, greyed: false,
                                      detail: "Battery \(battery.text) \u{00B7} enough to get there, you can charge at the end")
            }
            return RouteFitResult(status: .fits, sparePct: spare, chip: nil, greyed: false, detail: nil)
        }
        guard let back = backNeededPct else { return .silent }
        let spare = now - (there + back + reservePct)
        if spare < -eps {
            return RouteFitResult(status: .oneWayOnly, sparePct: spare, chip: oneWayText, greyed: false,
                                  detail: "Battery \(battery.text) \u{00B7} enough to get there, not for the way back")
        }
        if spare + eps < T.t82SparePct {
            return RouteFitResult(status: .tight, sparePct: spare, chip: tightText, greyed: false,
                                  detail: "Battery \(battery.text) \u{00B7} barely enough for a round trip")
        }
        return RouteFitResult(status: .fits, sparePct: spare, chip: nil, greyed: false, detail: nil)
    }

    /// "5 min ago", "2 h ago", "3 days ago"
    public static func ageText(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(max(1, m)) min ago" }
        if m < 24 * 60 { return "\(m / 60) h ago" }
        let d = m / (24 * 60)
        return "\(d) \(d == 1 ? "day" : "days") ago"
    }
}
