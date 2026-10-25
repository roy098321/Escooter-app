import Foundation

/// Note 9 (owner 24 Oct): instead of a generic "Still learning…", one card per insight with a progress bar and two marks (early read ·
/// confident). From the early read (the engine's existing Medium level) the card shows a RANGE that shrinks as data grows
/// ("19–25 km/h" → "21–23 km/h"), tagged "early read", softer words; it may widen when rides disagree, and then says so. Early reads are
/// information only: they never drive warnings or estimates. Once confident (High) the insight graduates: the bar goes and it becomes
/// its own page, opened from Stats. Pages (accepted list): Speed · Battery · Charging · Hills · Wind · Temperature · Routes & places ·
/// Distance & time · Money & environment · Scooter health; each appears only when it has something confident to say. Pure, tested.

public enum InsightStage: String, Sendable {
    case learning, early, confident
}

/// The Stats pages a confident insight graduates into
public enum InsightPage: String, CaseIterable, Sendable {
    case speed = "Speed"
    case battery = "Battery"
    case charging = "Charging"
    case hills = "Hills"
    case wind = "Wind"
    case temperature = "Temperature"
    case routes = "Routes & places"
    case distance = "Distance & time"
    case money = "Money & environment"
    case health = "Scooter health"

    public static func of(_ topic: InsightCard.Topic) -> InsightPage {
        switch topic {
        case .sweetSpot: return .speed
        case .creep: return .battery
        case .departure: return .routes
        case .wind: return .wind
        }
    }

    public var symbol: String {
        switch self {
        case .speed: return "speedometer"
        case .battery: return "battery.75percent"
        case .charging: return "bolt"
        case .hills: return "mountain.2"
        case .wind: return "wind"
        case .temperature: return "thermometer.medium"
        case .routes: return "point.topleft.down.to.point.bottomright.curvepath"
        case .distance: return "clock"
        case .money: return "leaf"
        case .health: return "wrench.and.screwdriver"
        }
    }
}

/// One graduated page and the confident insight behind it
public struct InsightPageEntry: Equatable, Sendable, Identifiable {
    public var page: InsightPage
    public var card: InsightCard
    public var id: String { page.rawValue }
}

public struct InsightProgress: Equatable, Sendable, Identifiable {
    public var topic: InsightCard.Topic
    /// "Speed sweet spot"
    public var title: String
    /// What it counts so far (nil when the engine says something else, e.g. "no clear lowest point yet")
    public var have: Int?
    /// The early-read mark and the confident mark, in the same unit
    public var earlyAt: Int
    public var confidentAt: Int
    /// "steady stretches" / "rides"
    public var unit: String
    public var stage: InsightStage
    /// From the early read: "26–30 km/h"
    public var range: String?
    /// Words after the range: "least battery per km"
    public var rangeContext: String?
    /// The range got wider than the last one shown
    public var widened = false
    /// The engine's own words when it has no count ("no clear lowest point yet")
    public var note: String?
    /// The card behind it (the detail page), nil while learning
    public var card: InsightCard?

    public var id: String { topic.rawValue }

    /// 0...1 along the bar (the confident mark at the end)
    public var fraction: Double {
        guard let have, confidentAt > 0 else { return 0 }
        return min(1, max(0, Double(have) / Double(confidentAt)))
    }

    public var earlyMark: Double { confidentAt > 0 ? min(1, Double(earlyAt) / Double(confidentAt)) : 0 }

    /// "5 of 12 steady stretches to a first read" / "14 of 30 to confident"
    public var countLine: String {
        if let have {
            return stage == .learning ? "\(have) of \(earlyAt) \(unit) to a first read" : "\(have) of \(confidentAt) to confident"
        }
        return note.map { "Not yet: \($0)" } ?? "No answer yet"
    }

    public var widenedLine: String? { widened ? "Wider than before: your recent rides disagree." : nil }
}

public enum InsightProgressBuilder {
    /// (title, unit, early mark, confident mark) per topic
    public static func marks(_ topic: InsightCard.Topic) -> (title: String, unit: String, early: Int, confident: Int) {
        switch topic {
        case .sweetSpot: return ("Speed sweet spot", "steady stretches", InsightGate.sweetMediumStretches, InsightGate.sweetHighStretches)
        case .departure: return ("Best time to leave", "rides on your usual route", DepartureInsight.minRides, 2 * InsightGate.departHighPerWindow)
        case .creep: return ("Battery use over time", "rides", InsightGate.creepMediumRides, InsightGate.creepHighRides)
        case .wind: return ("What wind costs you", "rides with wind data", InsightGate.windMediumRides, InsightGate.windHighRides)
        }
    }

    /// The leading count of an engine's learning words: "12 of 30 steady stretches" → 12
    public static func count(_ words: String) -> Int? {
        let parts = words.split(separator: " ")
        guard parts.count >= 3, parts[1] == "of" else { return nil }
        return Int(parts[0])
    }

    /// "Sweet spot between 26 and 30 km/h." → ("26–30 km/h", width 4); "Between +1 and +3 % per km." → ("+1–+3 % per km", 2)
    public static func range(_ interval: String) -> (text: String, width: Double?)? {
        let lower = interval.lowercased()
        guard let b = lower.range(of: "between ") else { return nil }
        let rest = interval[b.upperBound...]
        guard let and = rest.range(of: " and ") else { return nil }
        let a = String(rest[..<and.lowerBound])
        var tail = String(rest[and.upperBound...]).trimmingCharacters(in: .whitespaces)
        if tail.hasSuffix(".") { tail.removeLast() }
        let bits = tail.split(separator: " ", maxSplits: 1).map(String.init)
        guard let second = bits.first else { return nil }
        let unit = bits.count > 1 ? " " + bits[1] : ""
        func number(_ s: String) -> Double? {
            let clean = s.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "\u{2212}", with: "-")
            if clean.contains(":") {
                let hm = clean.split(separator: ":").compactMap { Double($0) }
                return hm.count == 2 ? hm[0] * 60 + hm[1] : nil
            }
            return Double(clean)
        }
        let width = number(a).flatMap { x in number(second).map { abs($0 - x) } }
        return ("\(a)\u{2013}\(second)\(unit)", width)
    }

    /// The cards for Stats (not graduated, wind stays a Home "today" card) and the graduated pages.
    /// `previousWidths`: the range width last shown per topic (to say when it widened).
    public static func make(_ outcomes: [InsightOutcome], previousWidths: [String: Double] = [:])
        -> (progress: [InsightProgress], pages: [InsightPageEntry], widths: [String: Double]) {
        var progress: [InsightProgress] = []
        var pages: [InsightPageEntry] = []
        var widths = previousWidths
        for o in outcomes where o.topic != .wind {
            let m = marks(o.topic)
            switch o {
            case .learning(let topic, let words):
                let have = count(words)
                progress.append(InsightProgress(topic: topic, title: m.title, have: have, earlyAt: m.early, confidentAt: m.confident, unit: m.unit,
                                                stage: .learning, note: have == nil ? words : nil))
            case .card(let c):
                if c.certainty.level == .high {
                    pages.append(InsightPageEntry(page: InsightPage.of(c.topic), card: c))
                    continue
                }
                let have = c.topic == .sweetSpot ? (c.chart?.dots.count ?? c.evidence.rides) : c.evidence.rides
                let early = c.certainty.level == .medium
                var p = InsightProgress(topic: c.topic, title: m.title, have: have, earlyAt: m.early, confidentAt: m.confident, unit: m.unit,
                                        stage: early ? .early : .learning, card: early ? c : nil)
                if early, let r = range(c.certainty.interval) {
                    p.range = r.text
                    p.rangeContext = c.topic == .sweetSpot ? "least battery per km" : nil
                    if let w = r.width {
                        if let before = previousWidths[c.topic.rawValue], w > before * 1.05 + 1e-9 { p.widened = true }
                        widths[c.topic.rawValue] = w
                    }
                }
                progress.append(p)
            }
        }
        pages.sort { (InsightPage.allCases.firstIndex(of: $0.page) ?? 0) < (InsightPage.allCases.firstIndex(of: $1.page) ?? 0) }
        return (progress, pages, widths)
    }
}
