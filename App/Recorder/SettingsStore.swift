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

    /// The rider's battery size for the active scooter, else its model's pack (B102 .05: G500 = 21 Ah), else T42.
    /// Hotfix .07: a stored size that is not one of the model's sizes (a G100 value on a G500) is ignored.
    static func packAh(_ db: AppDatabase?) -> Double {
        riderPackAh(db) ?? ScooterModels.pack(model: activeModel(db))?.packAh ?? T.t42DefaultPackAh
    }

    /// Hotfix .07: the size the rider picked for the active scooter, when it is one of the model's sizes
    static func riderPackAh(_ db: AppDatabase?) -> Double? {
        guard let v = SettingsValue.number(db, packAhKey) else { return nil }
        let model = activeModel(db)
        if ScooterModels.pack(model: model) != nil, !ScooterModels.packChoices(model: model).contains(v) { return nil }
        return v
    }

    /// Hotfix .07: the sizes Settings offers for the active scooter's model (G100: 16 / 15 / 13; G500: 21)
    static func packChoices(_ db: AppDatabase?) -> [Double] { ScooterModels.packChoices(model: activeModel(db)) }

    /// Hotfix .07: the active scooter's pack voltage for Wh maths (model, else learned class, else 48 V)
    static func packV(_ db: AppDatabase?) -> Double {
        ScooterModels.packV(model: activeModel(db), learnedClassV: SettingsValue.number(db, "scooter.voltageClass"))
    }

    /// The Garage's active scooter model ("RND G500"); nil before any scooter
    static func activeModel(_ db: AppDatabase?) -> String? {
        let r = GarageService.registry(db)
        return r.scooters.first { $0.id == r.activeId }?.model
    }
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

/// D2 4b: every alert has its own switch (all on by default), in groups
enum NotifyKind: String, CaseIterable {
    case switchOn, arriveBy, charge, weekly, wind, maintenance, wear

    var key: String { "notify.\(rawValue)" }

    var title: String {
        switch self {
        case .switchOn: return "Going for a ride? (when your scooter is ready)"
        case .arriveBy: return "Arrive-by: time to leave"
        case .charge: return "Charge alerts"
        case .weekly: return "Weekly summary (Sun 7:30)"
        case .wind: return "Wind picking up"
        case .maintenance: return "Maintenance due"
        case .wear: return "Battery wear"
        }
    }

    /// The group heading in Settings
    var group: String {
        switch self {
        case .switchOn, .arriveBy: return "Rides"
        case .charge: return "Charging"
        case .weekly, .wind, .maintenance, .wear: return "Tips (2 a day at most)"
        }
    }

    static let groups = ["Rides", "Charging", "Tips (2 a day at most)"]
    static func kinds(in group: String) -> [NotifyKind] { allCases.filter { $0.group == group } }

    /// The one alert that has no switch: the build is about to stop working
    static let alwaysOn = "Test build about to expire (or the app stops)"
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
