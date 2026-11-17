import AppIntents
import CorckieCore

/// M1-11: Siri / Shortcuts "Start ride" (the intent itself is in Shared/RideActivity, N7-1 / N7-9).
struct CorckieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRideIntent(), phrases: ["Start ride in \(.applicationName)"],
                    shortTitle: "Start ride", systemImageName: "scooter")
    }
}
