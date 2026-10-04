import AppIntents
import CorckieCore

/// M1-11: App Shortcut "Start ride" (fallback #4, check l8): Siri / Shortcuts can press Start ride while the scooter
/// is connected. It does the same as Home's Start ride: the ride engine refuses it when the scooter is not
/// connected (no ride starts before the connection is confirmed). Read-only link: nothing is sent to the scooter.
struct StartRideIntent: AppIntent {
    static var title: LocalizedStringResource = "Start ride"
    static var description = IntentDescription("Starts recording a ride while your scooter is connected.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        RecorderService.shared.press(.startPressed)
        return .result()
    }
}

struct CorckieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRideIntent(), phrases: ["Start ride in \(.applicationName)"],
                    shortTitle: "Start ride", systemImageName: "scooter")
    }
}
