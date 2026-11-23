import Foundation

/// Batch 9 (N9-2, new-rider audit 18 Nov 2026): the first-launch and empty-app rules, kept here so Linux CI tests them.
public enum NewRider {
    // MARK: First open

    /// A-01: a fresh install opens onboarding by itself (not only from the Connect button): onboarding never finished and no
    /// scooter is paired. A rider who tapped "Set up later" finished onboarding, so it is not forced again.
    public static func opensOnboarding(onboardingDone: Bool, paired: Bool) -> Bool { !onboardingDone && !paired }

    /// A-02: a fresh install never sees "What's new": nothing was ever seen, onboarding never finished, no scooter paired.
    /// The current build is then marked as seen silently, so the card only shows after a later update.
    public static func isFreshInstall(lastSeenWhatsNew: String?, onboardingDone: Bool, paired: Bool) -> Bool {
        lastSeenWhatsNew == nil && !onboardingDone && !paired
    }

    /// A-03: no outside data (weather, holidays, elevation) and no location fix before onboarding is done (or a scooter is
    /// paired, for riders from before onboarding existed) and location was allowed, so no iOS pop-up shows up without a reason.
    public static func outsideDataAllowed(onboardingDone: Bool, paired: Bool, locationAllowed: Bool) -> Bool {
        (onboardingDone || paired) && locationAllowed
    }

    /// A-04: holidays come from Hebcal (the Israeli calendar) only for riders whose phone region is Israel; elsewhere none for now.
    public static func usesHebcalHolidays(regionCode: String?) -> Bool { regionCode?.uppercased() == "IL" }

    // MARK: Empty app

    /// A-10: the Load row on Home waits for a few rides (it means nothing on day 0)
    public static let loadRowAfterRides = 3
    public static func showsLoadRow(rides: Int) -> Bool { rides >= loadRowAfterRides }

    /// A-27: day-0 Home is the status and the Start disc. The Where to? row comes back with the first ride or the first saved place.
    public static func showsWhereTo(rides: Int, places: Int) -> Bool { rides > 0 || places > 0 }

    /// A-11: one line on the empty lists, saying how they fill
    public static let emptyRoutesHint = "Routes appear after you ride the same trip twice."
    public static let emptyStatsHint = "Your weeks and months fill in as you ride."

    // MARK: Setup

    /// A-07: onboarding uses Home's rule: after 30 s without the scooter it says "Can't find it" and what to try
    public static let cantFindAfterS: Double = 30
    public static func cantFind(searchingSinceS: Double?, nowS: Double, found: Bool) -> Bool {
        guard !found, let since = searchingSinceS else { return false }
        return nowS - since >= cantFindAfterS
    }

    public static let cantFindTitle = "Can't find your scooter"
    public static let cantFindTips = ["Switch the scooter on and wait for its screen.",
                                      "Hold the phone within a few metres of it.",
                                      "Close other scooter apps: one app at a time can connect."]
    /// "Which scooters work?": the scooters the app reads today (KnownScooters); others are not found yet
    public static let supportedLine = "CorckieApp reads RND scooters (G100, G500) today. Other brands are not supported yet."

    /// A-13: the scooter card's default name is the model name the scooter reports, not a fixed "G2"
    public static func cardName(foundModel: String?) -> String {
        let m = foundModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return m.isEmpty ? "Scooter" : m
    }

    /// A-21: one calm safety line in onboarding
    public static let safetyLine = "Keep your eyes on the road: the app talks, you don't need to touch the phone while riding."

    /// A-09: plain words for the alerts step
    public static let alertsLine = "When your scooter is ready, and when charging is done. Tips: two a day at most."

    /// A-08: While Using now; Always is asked later by iOS, with this line explaining why
    public static let locationLine = "Tap Allow While Using. Later iOS asks to change to Always: say yes, so rides record with the phone locked. Then allow Motion, for climbs."

    /// A-24: the credits the map and weather licences require, shown to every rider in Settings → About → Credits
    public struct Credit: Hashable, Sendable {
        public var what: String
        public var who: String
    }

    public static let credits: [Credit] = [
        Credit(what: "Map tiles", who: "\u{00A9} OpenStreetMap contributors \u{00A9} CARTO"),
        Credit(what: "Weather", who: "Open-Meteo.com (CC BY 4.0) and MET Norway (CC BY 4.0)"),
        Credit(what: "Holidays", who: "Hebcal (CC BY 4.0)"),
        Credit(what: "Fuel price", who: "Israel Ministry of Energy"),
    ]
    public static var creditsLine: String { credits.map { "\($0.what): \($0.who)" }.joined(separator: " \u{00B7} ") }

    // MARK: Welcome (A-06, owner 18 Nov, D-PR-10)

    public struct TourCard: Equatable, Sendable {
        /// SF Symbol
        public var symbol: String
        public var title: String
        public var line: String
    }

    public static let welcomeTitle = "Know your scooter. Every ride."
    public static let welcomeLine = "Rides record themselves. Range in km, voice in your earbuds, smart charging."
    public static let welcomeTourButton = "See what it does"
    public static let welcomeStartButton = "Get started"

    /// The optional tour: 7 short cards, only what the app does today (no card for a feature that is not built)
    public static let tour: [TourCard] = [
        TourCard(symbol: "play.circle", title: "Rides record themselves", line: "Switch on and go. Phone stays in your pocket."),
        TourCard(symbol: "headphones", title: "Voice in your earbuds", line: "Battery, arrival time and warnings."),
        TourCard(symbol: "gauge.with.dots.needle.67percent", title: "Live dashboard", line: "Speed, battery and distance on a map."),
        TourCard(symbol: "chart.xyaxis.line", title: "Every ride, analysed", line: "Compare rides. See your weeks and months."),
        TourCard(symbol: "bolt", title: "Smart charging", line: "Know when you have enough for the ride ahead."),
        TourCard(symbol: "battery.75", title: "Battery and care", line: "Battery health and maintenance reminders."),
        TourCard(symbol: "mappin.and.ellipse", title: "Find where you parked", line: "Your last stop, saved on a map."),
    ]

    /// The tour's button: Next, and Get started on the last card
    public static func tourButton(card: Int) -> String { card >= tour.count - 1 ? welcomeStartButton : "Next" }
}
