import Foundation

/// M4-05: the smart prompt (C26, CALC_SPEC 9.5, T97) and the Loaded tag (M23).
/// One card on the ride summary when a ride on a saved route (5 rides or more) used noticeably more battery than usual (M14,
/// 2% or more) and the known factors leave 2% or more unexplained. At most once a day; 2 dismissals in a row pause it for 7 days.
/// Answers: Light / Heavy load set the ride's load (kg), Tyres felt soft marks the ride "not typical" and makes the tyre
/// reminder due, Rode differently marks it "not typical", Not sure does nothing. An answer given 3 times or more becomes a row
/// on the Factors page. Pure logic; storage in the App layer.

public enum SmartAnswer: String, CaseIterable, Sendable {
    case light, heavy, tyresSoft, rodeDifferently, notSure

    public var title: String {
        switch self {
        case .light: return "Light load"
        case .heavy: return "Heavy load"
        case .tyresSoft: return "Tyres felt soft"
        case .rodeDifferently: return "Rode differently"
        case .notSure: return "Not sure"
        }
    }

    /// Load level stored on the ride (T75: Light 5 kg, Heavy 15 kg)
    public var loadLevel: LoadLevel? {
        switch self {
        case .light: return .light
        case .heavy: return .heavy
        default: return nil
        }
    }

    /// The ride is left out of every usual range
    public var excludesFromUsual: Bool { self == .tyresSoft || self == .rodeDifferently }

    /// The tyre reminder becomes due
    public var makesTyresDue: Bool { self == .tyresSoft }

    /// Becomes a Factors row after this many answers
    public static let factorRowAfter = 3
}

/// The Loaded tag (M23, T75): None 0 / Light 5 / Heavy 15 kg, or an exact number of kg.
public enum LoadLevel: String, CaseIterable, Sendable {
    case none, light, heavy, custom

    public var title: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .heavy: return "Heavy"
        case .custom: return "Exact kg"
        }
    }

    /// kg of the preset levels; custom has its own number
    public var presetKg: Double? {
        switch self {
        case .none: return 0
        case .light: return 5
        case .heavy: return 15
        case .custom: return nil
        }
    }

    /// The text of the tag: "None", "Light (5 kg)", "Heavy (15 kg)", "7 kg"
    public static func label(level: String?, kg: Double?) -> String {
        guard let level, let l = LoadLevel(rawValue: level) else { return "Not set" }
        switch l {
        case .none: return "None"
        case .light, .heavy: return "\(l.title) (\(Int((kg ?? l.presetKg ?? 0).rounded())) kg)"
        case .custom: return "\(Int((kg ?? 0).rounded())) kg"
        }
    }
}

public struct SmartPromptState: Equatable, Sendable {
    /// Local day number (days since 1970) the card was last shown on, and for which ride
    public var lastShownDay: Int64?
    public var lastShownRideId: String?
    public var dismissStreak: Int
    public var pausedUntilMs: Int64?

    public init(lastShownDay: Int64? = nil, lastShownRideId: String? = nil, dismissStreak: Int = 0, pausedUntilMs: Int64? = nil) {
        self.lastShownDay = lastShownDay
        self.lastShownRideId = lastShownRideId
        self.dismissStreak = dismissStreak
        self.pausedUntilMs = pausedUntilMs
    }
}

public struct SmartPromptCard: Equatable, Sendable {
    public var rideId: String
    public var text: String
    public var extraPct: Double
    public var answers: [SmartAnswer]

    public init(rideId: String, text: String, extraPct: Double, answers: [SmartAnswer]) {
        self.rideId = rideId
        self.text = text
        self.extraPct = extraPct
        self.answers = answers
    }
}

public enum SmartPrompt {
    public static let pauseDays = 7
    public static let dismissalsToPause = 2

    public static func localDay(nowMs: Int64, utcOffsetMin: Int) -> Int64 {
        Int64((Double(nowMs + Int64(utcOffsetMin) * 60_000) / Double(OutsideTime.dayMs)).rounded(.down))
    }

    /// The card for a ride, or nil. `usualUsed` = the usual battery range of the route's other rides (M13, 5 rides).
    public static func card(rideId: String, routeRides: Int, usedPct: Double?, usualUsed: UsualRangeValue?, explanation: RideExplanation?,
                            alreadyAnswered: Bool = false, state: SmartPromptState, nowMs: Int64, utcOffsetMin: Int) -> SmartPromptCard? {
        guard !alreadyAnswered, routeRides >= T.t97SmartPromptRides, let used = usedPct, let range = usualUsed else { return nil }
        if let until = state.pausedUntilMs, nowMs < until { return nil }
        // once a day: the card of another ride already went today
        let today = localDay(nowMs: nowMs, utcOffsetMin: utcOffsetMin)
        if state.lastShownDay == today, let shown = state.lastShownRideId, shown != rideId { return nil }
        guard case .above = UsualRange.noticeablyDifferent(value: used, range: range, minimumStep: UsualRange.minimumBatteryStepPct) else { return nil }
        let extra = used - range.median
        guard extra >= T.t97SmartPromptPct else { return nil }
        // what the known factors leave unexplained (no explanation yet: all of it)
        let unexplained = explanation?.otherPct ?? extra
        guard unexplained >= T.t97SmartPromptPct else { return nil }
        let text = "This ride used \(Int(extra.rounded()))% more battery than usual. Wind, rush hour and load don't explain it. Anything different?"
        return SmartPromptCard(rideId: rideId, text: text, extraPct: extra, answers: SmartAnswer.allCases)
    }

    public static func afterShown(_ s: SmartPromptState, rideId: String, nowMs: Int64, utcOffsetMin: Int) -> SmartPromptState {
        var n = s
        n.lastShownDay = localDay(nowMs: nowMs, utcOffsetMin: utcOffsetMin)
        n.lastShownRideId = rideId
        return n
    }

    public static func afterAnswer(_ s: SmartPromptState) -> SmartPromptState {
        var n = s
        n.dismissStreak = 0
        return n
    }

    /// Dismissed without an answer: 2 in a row pause it for 7 days
    public static func afterDismiss(_ s: SmartPromptState, nowMs: Int64) -> SmartPromptState {
        var n = s
        n.dismissStreak += 1
        if n.dismissStreak >= dismissalsToPause {
            n.dismissStreak = 0
            n.pausedUntilMs = nowMs + Int64(pauseDays) * OutsideTime.dayMs
        }
        return n
    }
}
