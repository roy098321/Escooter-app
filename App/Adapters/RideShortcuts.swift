import AppIntents
import CorckieCore

/// M1-11: Siri / Shortcuts "Start ride" (the intent itself is in Shared/RideActivity, N7-1 / N7-9).
struct CorckieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRideIntent(), phrases: ["Start ride in \(.applicationName)"],
                    shortTitle: "Start ride", systemImageName: "scooter")
        // N7-9: "Ride to Work in CorckieApp"
        AppShortcut(intent: RideToPlaceIntent(), phrases: ["Ride to \(\.$place) in \(.applicationName)",
                                                           "Start a ride to \(\.$place) in \(.applicationName)"],
                    shortTitle: "Ride to a place", systemImageName: "mappin.and.ellipse")
    }
}
