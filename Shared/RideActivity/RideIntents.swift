import ActivityKit
import AppIntents
import Foundation

// N7-1 / N7-9 (batch 7): the ride actions shared by the Dynamic Island / Live Activity buttons, Control Center and Lock Screen
// controls, the Action button, Siri and Spotlight. Compiled into the app AND the widget extension (so the buttons can name them);
// they always run in the APP's process (LiveActivityIntent / openAppWhenRun), where the app has set `RideIntentBridge` at launch.
// Read-only link: nothing is ever sent to the scooter.

/// What the intents do, set by the app at launch (nil in the widget extension, which never runs them).
enum RideIntentBridge {
    /// Start a ride; the argument is a destination key (a quick-dial key, "next" = the usual one from here, nil = free ride)
    @MainActor static var start: ((String?) -> Void)?
    /// End the ride now (the Arrived card's End ride)
    @MainActor static var end: (() -> Void)?
    /// Keep riding after arriving (the card goes back to Recording)
    @MainActor static var keepGoing: (() -> Void)?
    /// Open the app on Home's "Where to?" (the Ready card's Change)
    @MainActor static var changeDestination: (() -> Void)?
}

/// N7-1: the Ready card's Change: opens the app on "Where to?"
struct ChangeDestinationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Change destination"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RideIntentBridge.changeDestination?()
        return .result()
    }
}

/// M1-11 + N7-9: "Start ride" (optionally to a place). Starting opens the Live screen. The ride engine refuses it when the scooter
/// is not connected, as Home's Start does.
struct StartRideIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start ride"
    static var description = IntentDescription("Starts recording a ride while your scooter is connected.")
    static var openAppWhenRun = true

    @Parameter(title: "Destination")
    var destination: String?

    init() {}
    init(destination: String?) { self.destination = destination }

    @MainActor
    func perform() async throws -> some IntentResult {
        RideIntentBridge.start?(destination)
        return .result()
    }
}

/// N7-1: the Arrived card's End ride
struct EndRideIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End ride"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        RideIntentBridge.end?()
        // Hotfix .10 (owner 24 Nov: End ride left the card up): the card closes here, whatever the app remembers. After iOS relaunched
        // the app in the background it had forgotten the card (or the ride had already ended), so nothing closed it.
        for a in Activity<ScooterActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        return .result()
    }
}

/// N7-1: the Arrived card's Keep going
struct KeepGoingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Keep going"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        RideIntentBridge.keepGoing?()
        return .result()
    }
}
