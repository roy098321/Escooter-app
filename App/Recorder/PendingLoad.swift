import CorckieCore
import Foundation

/// F-02: the Load chosen on Home waits here until the next ride starts; the Recorder attaches it to that ride and the choice resets to None.
/// The tag is the same one as the after-ride Loaded tag (columns loadLevel / loadKg), so the factors engine reads it unchanged at ride close.
enum PendingLoad {
    static let key = "home.nextLoad"

    static func get(_ db: AppDatabase?) -> LoadChoice {
        LoadChoice(stored: SettingsValue.text(db, key)) ?? .empty
    }

    static func set(_ db: AppDatabase?, _ choice: LoadChoice) {
        if choice.level == .none { SettingsValue.clear(db, key) } else { SettingsValue.set(db, key, choice.stored) }
    }

    /// Ride start: attaches the waiting choice to the ride (none = nothing is tagged) and resets it. Returns what was attached.
    @discardableResult
    static func attach(_ db: AppDatabase, rideId: String) -> (level: LoadLevel, kg: Double)? {
        let choice = get(db)
        defer { set(db, .empty) }
        guard let a = choice.attachment(lightKg: RiderSettings.kg(db, .light) ?? 5, heavyKg: RiderSettings.kg(db, .heavy) ?? 15) else { return nil }
        try? SmartPromptQueries(db).setLoad(rideId: rideId, level: a.level.rawValue, kg: a.kg)
        return a
    }
}
