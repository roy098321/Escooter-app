import CorckieCore
import Foundation

// M5-06: the values behind the Settings screen (FEATURES.md, C23). All in the `setting` table (so backups and exports carry them);
// the display switches are also kept in UserDefaults because the drawing code asks for them many times a second.
// Compiled into AppTests with App/Store (the Recorder, the notifiers and the calibration read them).

enum SettingsValue {
    static func text(_ db: AppDatabase?, _ key: String) -> String? {
        guard let db, let s = try? RideQueries(db).setting(key: key), !s.isEmpty else { return nil }
        return s
    }

    static func number(_ db: AppDatabase?, _ key: String) -> Double? {
        text(db, key).flatMap { Double($0) }
    }

    static func flag(_ db: AppDatabase?, _ key: String, default value: Bool) -> Bool {
        guard let s = text(db, key) else { return value }
        return s == "1" || s == "true"
    }

    static func set(_ db: AppDatabase?, _ key: String, _ value: String) {
        guard let db, !db.isReadOnly else { return }
        try? RideQueries(db).setSetting(key: key, json: value)
    }

    static func setFlag(_ db: AppDatabase?, _ key: String, _ on: Bool) { set(db, key, on ? "1" : "0") }

    static func clear(_ db: AppDatabase?, _ key: String) {
        guard let db, !db.isReadOnly else { return }
        try? db.writer.write { try $0.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key]) }
    }
}

/// Battery size, charger and "Recalibrate battery"
enum BatterySettings {
    static let packAhKey = "battery.packAh"
    static let chargerKey = "battery.chargerA"
    static let recalibrateKey = "battery.recalibrateFromMs"

    static func packAh(_ db: AppDatabase?) -> Double { SettingsValue.number(db, packAhKey) ?? T.t42DefaultPackAh }
    static func chargerA(_ db: AppDatabase?) -> Double { SettingsValue.number(db, chargerKey) ?? T.t46ChargerA }
    /// Rides that started before this are left out of the calibration (0 = all rides count)
    static func recalibrateFromMs(_ db: AppDatabase?) -> Int64 { Int64(SettingsValue.number(db, recalibrateKey) ?? 0) }

    /// A new battery size: the calibration, the used % of every ride and Stats follow
    static func setPackAh(_ db: AppDatabase, _ ah: Double, nowMs: Int64 = FactorUpdater.nowMs()) {
        SettingsValue.set(db, packAhKey, String(ah))
        _ = try? CalibrationUpdater.update(db, nowMs: nowMs)
    }

    static func setChargerA(_ db: AppDatabase, _ amps: Double) { SettingsValue.set(db, chargerKey, String(amps)) }

    /// M8 S7: starts a new calibration over the next qualifying rides (older rides stay, they just stop teaching the calibration)
    static func recalibrate(_ db: AppDatabase, nowMs: Int64 = FactorUpdater.nowMs()) {
        SettingsValue.set(db, recalibrateKey, String(nowMs))
        _ = try? CalibrationUpdater.update(db, nowMs: nowMs)
    }
}

/// The four notification switches (all on by default)
enum NotifyKind: String, CaseIterable {
    case weekly, wind, arriveBy, maintenance

    var key: String { "notify.\(rawValue)" }

    var title: String {
        switch self {
        case .weekly: return "Weekly summary (Sun 7:30)"
        case .wind: return "Wind picking up"
        case .arriveBy: return "Arrive-by reminders"
        case .maintenance: return "Maintenance due"
        }
    }
}

enum NotifyPrefs {
    static func isOn(_ db: AppDatabase?, _ kind: NotifyKind) -> Bool {
        guard db != nil else { return true }
        return SettingsValue.flag(db, kind.key, default: true)
    }

    static func set(_ db: AppDatabase?, _ kind: NotifyKind, _ on: Bool) { SettingsValue.setFlag(db, kind.key, on) }
}

/// Light / Heavy in kg (defaults 5 and 15) and the optional rider weight
enum RiderSettings {
    static let lightKey = "rider.loadLightKg"
    static let heavyKey = "rider.loadHeavyKg"
    static let weightKey = "rider.weightKg"

    static func kg(_ db: AppDatabase?, _ level: LoadLevel) -> Double? {
        switch level {
        case .light: return SettingsValue.number(db, lightKey) ?? level.presetKg
        case .heavy: return SettingsValue.number(db, heavyKey) ?? level.presetKg
        default: return level.presetKg
        }
    }

    static func weightKg(_ db: AppDatabase?) -> Double? { SettingsValue.number(db, weightKey) }
}

/// Sunlight mode and the colour-blind speed colours
enum DisplaySettings {
    enum Sunlight: String, CaseIterable {
        case auto = "Auto", on = "On", off = "Off"
    }

    static let sunlightKey = "display.sunlight"
    static let colourBlindKey = "display.colourBlind"

    static var colourBlind: Bool { UserDefaults.standard.bool(forKey: colourBlindKey) }

    static func sunlight(_ db: AppDatabase?) -> Sunlight {
        Sunlight(rawValue: SettingsValue.text(db, sunlightKey) ?? "") ?? .auto
    }

    static func setSunlight(_ db: AppDatabase?, _ value: Sunlight) { SettingsValue.set(db, sunlightKey, value.rawValue) }

    static func setColourBlind(_ db: AppDatabase?, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: colourBlindKey)
        SettingsValue.setFlag(db, colourBlindKey, on)
    }
}
