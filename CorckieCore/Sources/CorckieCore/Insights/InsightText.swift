import Foundation

// M4-03: the words and numbers of every insight (INSIGHTS.md examples). Numbers shown are honest: no 10% margin here,
// the margin is only in the decisions (`SafetyMargin.forDecision`, Q2-live / Q9). No reward words (policy P-3): no records,
// goals, ghosts, streaks, badges or praise; a guard test scans every template and every string in this folder.

public enum InsightText {
    /// "40 s", "1:10", "12 min" (a duration, always positive)
    public static func duration(_ seconds: Double) -> String {
        let s = Int(abs(seconds).rounded())
        if s < 60 { return "\(s) s" }
        if s < 600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return "\(Int((Double(s) / 60).rounded())) min"
    }

    /// "2 min", "1.5 min", "1 min" (a headline difference; at least 1 min is said as minutes)
    public static func minutes(_ seconds: Double) -> String {
        let m = abs(seconds) / 60
        if m < 1 { return duration(seconds) }
        let half = (m * 2).rounded() / 2
        if half == half.rounded() || half >= 10 { return "\(Int(half.rounded())) min" }
        return String(format: "%.1f min", half)
    }

    /// "13–16 min" from seconds
    public static func minuteRange(_ lo: Double, _ hi: Double) -> String {
        let a = Int((lo / 60).rounded()), b = Int((hi / 60).rounded())
        return a == b ? "\(a) min" : "\(a)–\(b) min"
    }

    /// "3%" (honest, rounded; under 1 shown with one decimal)
    public static func pct(_ p: Double) -> String {
        let a = abs(p)
        if a > 0, a < 1 { return String(format: "%.1f%%", a) }
        return "\(Int(a.rounded()))%"
    }

    /// "+2%" / "−1%"
    public static func signedPct(_ p: Double) -> String { (p < 0 ? "\u{2212}" : "+") + pct(p) }

    /// "+30 s" / "−1:10"
    public static func signedDuration(_ s: Double) -> String { (s < 0 ? "\u{2212}" : "+") + duration(s) }

    /// "0.8 km"
    public static func km(_ metres: Double) -> String { String(format: "%.1f km", abs(metres) / 1000) }

    /// "based on 8 rides" / "based on 1 ride"
    public static func basedOn(_ n: Int) -> String { "based on \(n) \(n == 1 ? "ride" : "rides")" }

    /// The factor's name in a sentence (factor id + level of `FactorEffect` / `RideExplanation.Item`)
    public static func factorLabel(factorId: String, level: String) -> String {
        if factorId.contains("+") {
            let ids = factorId.split(separator: "+").map(String.init)
            let levels = level.split(separator: "+").map(String.init)
            return zip(ids, levels + Array(repeating: "", count: max(0, ids.count - levels.count)))
                .map { factorLabel(factorId: $0.0, level: $0.1) }.joined(separator: " + ")
        }
        switch factorId {
        case "W1": return level == "tail" ? "tailwind" : "headwind"
        case "W3": return "wet roads"
        case "R1": return "hills"
        case "T1": return "rush hour"
        case "T2": return level == "saturday" ? "a Saturday" : "a Friday"
        case "L1": return "load"
        case "D1": return "gear"
        case "D2": return "time at the speed cap"
        default: return factorId
        }
    }

    /// What the rides "with" a factor are called in a progress line ("2 of 3 windy rides")
    public static func withNoun(factorId: String, level: String) -> String {
        switch factorId {
        case "W1": return level == "tail" ? "tailwind rides" : "windy rides"
        case "W3": return "wet rides"
        case "R1": return "hilly rides"
        case "T1": return "rush-hour rides"
        case "T2": return level == "saturday" ? "Saturday rides" : "Friday rides"
        case "L1": return "loaded rides"
        default: return "rides with it"
        }
    }

    /// ... and the rides without it
    public static func withoutNoun(factorId: String, level: String) -> String {
        switch factorId {
        case "W1": return "calm rides"
        case "W3": return "dry rides"
        case "R1": return "flat rides"
        case "T1": return "other workday rides"
        case "T2": return "workday rides"
        case "L1": return "rides without a load"
        default: return "rides without it"
        }
    }

    /// Pattern D for a factor effect that does not pass its gate (M15): "2 of 3 windy rides", "1 of 3 calm rides",
    /// or "no clear effect yet (based on 12 rides)". nil when it passes.
    public static func progress(_ e: FactorEffect) -> String? {
        if e.passesGate { return nil }
        switch e.gate {
        case .notEnoughRides:
            if e.n < e.needed { return "\(e.n) of \(e.needed) \(withNoun(factorId: e.factorId, level: e.level))" }
            return "\(min(e.nWithout, e.needed)) of \(e.needed) \(withoutNoun(factorId: e.factorId, level: e.level))"
        case .combined:
            return "always together with another factor so far (\(basedOn(e.basedOnN)))"
        default:
            return "no clear effect yet (\(basedOn(e.basedOnN)))"
        }
    }

    /// The day's start of a sentence: "Home to Work" stays, an empty name becomes "this route"
    public static func route(_ name: String?) -> String {
        guard let n = name, !n.isEmpty else { return "this route" }
        return n
    }

    /// Capitalises the first letter ("headwind (~1:10)" → "Headwind (~1:10)")
    public static func capitalised(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    // MARK: P-3 guard

    /// Words and phrases no insight may contain (policy P-3: no rewards, records, goals, ghosts, streaks, praise).
    /// Checked by the Core test over every template and by the in-app check u32.
    public static let bannedPhrases = [
        "record", "personal best", "new best", "best ever", "your best", "streak", "goal", "ghost", "badge", "trophy",
        "high score", "achievement", "achieved", "congrat", "well done", "great job", "good job", "nice work", "awesome",
        "amazing", "keep it up", "level up", "beat your", "challenge", "medal", "reward", "!"
    ]

    /// The banned phrases a text contains (empty = clean)
    public static func bannedIn(_ text: String) -> [String] {
        let lower = text.lowercased()
        return bannedPhrases.filter { lower.contains($0) }
    }
}
