import Foundation

/// M4-08: the Factors page ("What affects my rides", IA: Stats). One row per factor level with what it costs in time and battery and
/// "based on N rides"; a factor that does not pass its gate (M15) shows its progress instead (pattern D, "2 of 3 windy rides").
/// Per trip = the effects on one route (time and battery per trip); per km = all routes pooled (per km, load per km per kg).
/// Pure text; the effects come from `FactorEffects.forRoute` / `forPooled`. No effect value is ever shown below its gate.

public struct FactorsRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// "+1:00 min per trip" / "+8 s per km"; nil when the gate is not met
    public var timeText: String?
    /// "+1% battery per trip" / "+0.40% battery per km"
    public var batteryText: String?
    /// "based on 9 rides" when an effect is shown
    public var basedOn: String?
    /// Pattern D line when the gate is not met ("2 of 3 windy rides")
    public var progress: String?
    /// L1 outside the physics range
    public var uncertain: Bool

    public var hasEffect: Bool { timeText != nil || batteryText != nil }
}

public enum FactorsPage {
    public static func rows(_ effects: [FactorEffect]) -> [FactorsRow] {
        var order: [String] = []
        var groups: [String: [FactorEffect]] = [:]
        for e in effects {
            let key = "\(e.factorId)|\(e.level)|\(e.scope.rawValue)|\(e.routeId ?? "")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        var out: [FactorsRow] = []
        for key in order {
            guard let list = groups[key], let first = list.first else { continue }
            let time = list.first { $0.quantity == .time }
            let used = list.first { $0.quantity == .used }
            let pooled = first.scope == .pooled
            let perKg = first.factorId == "L1"
            let unit = pooled ? (perKg ? "per km per kg" : "per km") : "per trip"
            var timeText: String?
            var batteryText: String?
            if let s = time?.timeEffectS {
                let amount = abs(s) < 60 ? "\(Int(abs(s).rounded())) s" : InsightText.minutes(s)
                timeText = (s < 0 ? "\u{2212}" : "+") + amount + " \(unit)"
            }
            if let p = used?.usedEffectPct {
                batteryText = pooled ? (p < 0 ? "\u{2212}" : "+") + String(format: "%.2f", abs(p)) + "% battery \(unit)"
                                     : "\(InsightText.signedPct(p)) battery \(unit)"
            }
            let shown = list.filter(\.passesGate)
            var basedOn: String?
            var progress: String?
            if let n = shown.map(\.basedOnN).max() {
                basedOn = InsightText.basedOn(n)
            } else {
                progress = list.compactMap { InsightText.progress($0) }.first
            }
            let title = InsightText.capitalised(InsightText.factorLabel(factorId: first.factorId, level: first.level.hasPrefix("perKg") ? "" : first.level))
            out.append(FactorsRow(id: key, title: title, timeText: timeText, batteryText: batteryText, basedOn: basedOn, progress: progress,
                                  uncertain: first.uncertain && (time?.passesGate == true || used?.passesGate == true)))
        }
        // rows with an effect first (largest time effect first), then the progress lines
        return out.enumerated().sorted { a, b in
            if a.element.hasEffect != b.element.hasEffect { return a.element.hasEffect }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Answers of the smart prompt given 3 times or more become a row ("Tyres felt soft: 4 times"; no effect is claimed)
    public static func answerRows(counts: [SmartAnswer: Int]) -> [FactorsRow] {
        SmartAnswer.allCases.compactMap { a in
            guard a == .tyresSoft || a == .rodeDifferently, let n = counts[a], n >= SmartAnswer.factorRowAfter else { return nil }
            return FactorsRow(id: "answer.\(a.rawValue)", title: a == .tyresSoft ? "Soft tyres" : "Rode differently", timeText: nil, batteryText: nil,
                              basedOn: "you said so \(n) times; those rides are left out of your usual range", progress: nil, uncertain: false)
        }
    }

    public static let emptyText = "No effects yet. They appear when a route has enough rides with and without wind, rain, rush hour or a load."
}
