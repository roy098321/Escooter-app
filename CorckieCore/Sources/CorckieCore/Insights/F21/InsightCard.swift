import Foundation

// F-21 (P6-4 chunk 3b): the reworked insights. An insight answers a question the rider asks and changes what they do: a headline of at
// most 8 words, one number, one action, the evidence behind it and how sure it is. Only Medium or High certainty is ever shown
// (`InsightGate`); the rest stays under "Still learning". The engines (`SweetSpotInsight`, `DepartureInsight`, `CreepInsight`,
// `WindTodayInsight`) are pure and unit tested; the app only loads the rides and draws the cards.

/// How sure an insight is. Only `.medium` and `.high` are shown.
public enum CertaintyLevel: Int, Comparable, Sendable, CaseIterable {
    case low = 0, medium = 1, high = 2

    public static func < (a: CertaintyLevel, b: CertaintyLevel) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// How full the "How sure" meter is drawn
    public var meter: Double {
        switch self {
        case .low: return 0.25
        case .medium: return 0.55
        case .high: return 0.8
        }
    }

    public var shown: Bool { self >= .medium }
}

/// The certainty of one insight: the level, the interval in words and how well the rides agree.
public struct InsightCertainty: Equatable, Sendable {
    public var level: CertaintyLevel
    /// "Sweet spot between 26 and 30 km/h."
    public var interval: String
    /// "Your rides agree within ±0.1 % per km. More rides make it sharper."
    public var agreement: String

    public init(level: CertaintyLevel, interval: String, agreement: String) {
        self.level = level
        self.interval = interval
        self.agreement = agreement
    }
}

/// What the insight is built from: "From 9 rides · 214 km, Sep 28 – Oct 19" and what was left out.
public struct InsightEvidence: Equatable, Sendable {
    public var rides: Int
    public var km: Double
    /// "Sep 28 – Oct 19"
    public var span: String
    /// "Only steady stretches (≥ 1 min at a constant speed). Climbs, stops and strong wind left out."
    public var exclusions: String

    public init(rides: Int, km: Double, span: String, exclusions: String) {
        self.rides = rides
        self.km = km
        self.span = span
        self.exclusions = exclusions
    }

    /// "9 rides · 214 km"
    public var bold: String { "\(rides) ride\(rides == 1 ? "" : "s") \u{00B7} \(Int(km.rounded())) km" }
}

/// One dot of the detail chart (one steady stretch, one ride, ...)
public struct InsightDot: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One point of the fitted curve with its confidence band; `segment` separates lines that must not join.
public struct InsightCurvePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var lo: Double
    public var hi: Double
    public var segment: Int
    public init(x: Double, y: Double, lo: Double, hi: Double, segment: Int = 0) {
        self.x = x
        self.y = y
        self.lo = lo
        self.hi = hi
        self.segment = segment
    }
}

/// The chart of the owner's own data behind an insight.
public struct InsightChart: Equatable, Sendable {
    /// Section title: "Your rides, battery per km by speed"
    public var title: String
    public var dots: [InsightDot]
    public var curve: [InsightCurvePoint]
    /// The highlighted x band (the sweet spot interval, the best departure window, the recent rides)
    public var band: ClosedRange<Double>?
    /// The x axis: values with their labels
    public var xTicks: [Double]
    public var xLabels: [String]
    /// The y axis: values with their labels
    public var yTicks: [Double]
    public var yLabels: [String]
    /// "Dots = your stretches of steady riding · band = how sure we are"
    public var caption: String

    public init(title: String, dots: [InsightDot], curve: [InsightCurvePoint], band: ClosedRange<Double>?, xTicks: [Double], xLabels: [String],
                yTicks: [Double], yLabels: [String], caption: String) {
        self.title = title
        self.dots = dots
        self.curve = curve
        self.band = band
        self.xTicks = xTicks
        self.xLabels = xLabels
        self.yTicks = yTicks
        self.yLabels = yLabels
        self.caption = caption
    }

    public var xDomain: ClosedRange<Double> {
        let xs = dots.map(\.x) + curve.map(\.x) + xTicks
        guard let lo = xs.min(), let hi = xs.max(), hi > lo else { return 0...1 }
        return lo...hi
    }

    public var yDomain: ClosedRange<Double> {
        let ys = dots.map(\.y) + curve.map(\.lo) + curve.map(\.hi) + yTicks
        guard let lo = ys.min(), let hi = ys.max(), hi > lo else { return 0...1 }
        let pad = (hi - lo) * 0.08
        return (lo - pad)...(hi + pad)
    }
}

/// The tone of a "what if" figure: better for the rider, worse, or just a figure.
public enum WhatIfTone: String, Sendable {
    case better, worse, neutral
}

public struct WhatIfItem: Equatable, Sendable {
    public var text: String
    public var tone: WhatIfTone
    public init(_ text: String, _ tone: WhatIfTone) {
        self.text = text
        self.tone = tone
    }
}

/// One row of the "What if" table: "23 km/h (−5)" → "+1 km range · +3 min to Work"
public struct WhatIfRow: Equatable, Sendable {
    public var label: String
    public var note: String
    public var items: [WhatIfItem]
    public var isBaseline: Bool
    public init(label: String, note: String = "", items: [WhatIfItem], isBaseline: Bool = false) {
        self.label = label
        self.note = note
        self.items = items
        self.isBaseline = isBaseline
    }
}

/// One F-21 insight, everything the card and the detail page show.
public struct InsightCard: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case today, pattern, maintenance
        /// The chip: TODAY / PATTERN / MAINTENANCE
        public var chip: String { rawValue.uppercased() }
    }

    /// Which engine made it (one card per topic)
    public enum Topic: String, Sendable, CaseIterable {
        case sweetSpot, departure, creep, wind

        /// The words of the "Still learning" line
        public var learningName: String {
            switch self {
            case .sweetSpot: return "your speed sweet spot"
            case .departure: return "the best time to leave"
            case .creep: return "battery use over time"
            case .wind: return "what wind costs you"
            }
        }
    }

    public var topic: Topic
    public var kind: Kind
    /// At most 8 words
    public var headline: String
    /// The one big number: "0.9", "+18", "−6"
    public var value: String
    /// Its unit: "%", "min"
    public var unit: String
    /// The words after it: "per km · vs 1.3 % at 40"
    public var context: String
    /// The one action: "Cruising at 28 gives you ~5 km more range"
    public var action: String
    /// The small line at the bottom: "Based on 9 rides"
    public var basedOn: String
    /// Detail: 1–2 plain sentences
    public var meaning: String
    public var chart: InsightChart?
    /// "What if you cruise…"
    public var whatIfTitle: String
    public var whatIf: [WhatIfRow]
    /// "Range from a full battery, on your usual routes and load."
    public var whatIfNote: String
    public var evidence: InsightEvidence
    /// The method, one line each, drawn in the formula box
    public var method: [String]
    public var certainty: InsightCertainty
    public var tryThis: String
    /// Ranking among the shown cards (bigger first)
    public var weight: Double

    public var id: String { topic.rawValue }

    public init(topic: Topic, kind: Kind, headline: String, value: String, unit: String, context: String, action: String, basedOn: String,
                meaning: String, chart: InsightChart?, whatIfTitle: String, whatIf: [WhatIfRow], whatIfNote: String, evidence: InsightEvidence,
                method: [String], certainty: InsightCertainty, tryThis: String, weight: Double = 0) {
        self.topic = topic
        self.kind = kind
        self.headline = headline
        self.value = value
        self.unit = unit
        self.context = context
        self.action = action
        self.basedOn = basedOn
        self.meaning = meaning
        self.chart = chart
        self.whatIfTitle = whatIfTitle
        self.whatIf = whatIf
        self.whatIfNote = whatIfNote
        self.evidence = evidence
        self.method = method
        self.certainty = certainty
        self.tryThis = tryThis
        self.weight = weight
    }

    public var headlineWords: Int { headline.split(separator: " ").count }
}

/// The result of one engine: the card (also when it is not sure enough, so a check can see it) or why there is none yet.
public enum InsightOutcome: Equatable, Sendable {
    /// Not enough data to even try: what is missing ("12 of 30 steady stretches")
    case learning(InsightCard.Topic, String)
    case card(InsightCard)

    public var card: InsightCard? {
        if case .card(let c) = self { return c }
        return nil
    }

    public var topic: InsightCard.Topic {
        switch self {
        case .learning(let t, _): return t
        case .card(let c): return c.topic
        }
    }

    /// Shown = a card at Medium or High
    public var shown: InsightCard? {
        guard let c = card, c.certainty.level.shown else { return nil }
        return c
    }
}

/// What the Stats tab shows: at most 3 cards, and the topics still learning.
public struct InsightBoard: Equatable, Sendable {
    public var cards: [InsightCard]
    public var learning: [InsightCard.Topic]

    public init(cards: [InsightCard], learning: [InsightCard.Topic]) {
        self.cards = cards
        self.learning = learning
    }

    public static let maxCards = 3

    /// Medium / High only, the most useful first, at most 3; everything else is "still learning". Today cards belong on Home only.
    public static func make(_ outcomes: [InsightOutcome]) -> InsightBoard {
        let shown = outcomes.compactMap(\.shown).filter { $0.kind != .today }
            .sorted { ($0.certainty.level, $0.weight) > ($1.certainty.level, $1.weight) }
        let picked = Array(shown.prefix(maxCards))
        let learning = outcomes.filter { o in o.topic != .wind && !picked.contains { $0.topic == o.topic } && o.shown == nil }.map(\.topic)
        return InsightBoard(cards: picked, learning: learning)
    }

    /// "Still learning: your speed sweet spot and the best time to leave. More rides make these sharper."
    public var learningLine: String? {
        guard !learning.isEmpty else { return nil }
        let names = learning.map(\.learningName)
        let list: String
        if names.count == 1 {
            list = names[0]
        } else {
            list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
        return "Still learning \(list). More rides make \(names.count == 1 ? "it" : "these") clear."
    }
}
