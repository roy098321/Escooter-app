import Foundation

/// M5-06: the Settings list of FEATURES.md (C23, 2026-10-01) as data: groups in order, rows and their defaults, tied to the real constants.
/// The Settings screen draws from it, and a test keeps it equal to the list in FEATURES.md and to the numbers the app really uses.
public struct SettingRow: Equatable, Sendable {
    public var id: String
    public var title: String
    public var defaultText: String

    public init(_ id: String, _ title: String, _ defaultText: String) {
        self.id = id
        self.title = title
        self.defaultText = defaultText
    }
}

public struct SettingGroup: Equatable, Sendable {
    public var title: String
    public var rows: [SettingRow]
    public var footer: String

    public init(_ title: String, _ rows: [SettingRow], footer: String = "") {
        self.title = title
        self.rows = rows
        self.footer = footer
    }
}

public enum SettingsCatalog {
    public static func ah(_ v: Double) -> String { v == v.rounded() ? "\(Int(v)) Ah" : String(format: "%.1f Ah", v) }

    public static var groups: [SettingGroup] {
        [
            SettingGroup("Battery and charging", [
                SettingRow("battery.packAh", "Battery size", ah(T.t42DefaultPackAh)),
                SettingRow("battery.chargerA", "Charger", String(format: "%.1f A", T.t46ChargerA)),
                SettingRow("battery.recalibrate", "Recalibrate battery", "Over the next 5 qualifying rides")
            ], footer: "The label under the deck has no capacity; 16 Ah matches what the rides measured. 13 Ah stays selectable."),
            SettingGroup("Units and display", [
                SettingRow("display.sunlight", "Sunlight mode", "Auto"),
                SettingRow("display.units", "Units", "km \u{00B7} \u{00B0}C"),
                SettingRow("display.colourBlind", "Colour-blind friendly speed colours", "Off")
            ], footer: "Units are fixed in v1. Sunlight mode is stored now; the display change arrives with the polish step."),
            SettingGroup("Costs", [
                SettingRow("stats.electricity", "Electricity price", String(format: "\u{20AA}%.2f / kWh", StatsPrices.defaultElectricityIlsPerKwh)),
                SettingRow("stats.fuelUse", "Car fuel use", "\(Int(StatsPrices.defaultFuelLPer100km)) L / 100 km"),
                SettingRow("fuelPrice", "Fuel price", "Manual \u{00B7} 8.27 \u{20AA}/L (Oct 2026)")
            ]),
            SettingGroup("Rider", [
                SettingRow("rider.weightKg", "Rider weight", "Not set"),
                SettingRow("rider.loads", "Load levels", "Light \(Int(LoadLevel.light.presetKg ?? 0)) kg \u{00B7} Heavy \(Int(LoadLevel.heavy.presetKg ?? 0)) kg")
            ]),
            SettingGroup("Voice and notifications", [
                SettingRow("notify.weekly", "Weekly summary (Sun 7:30)", "On"),
                SettingRow("notify.wind", "Wind picking up", "On"),
                SettingRow("notify.arriveBy", "Arrive-by reminders", "On"),
                SettingRow("notify.maintenance", "Maintenance due", "On")
            ], footer: "Never during a ride, nothing between 22:00 and 07:00, at most 2 a day. Voice updates: v2."),
            SettingGroup("Places", [
                SettingRow("places", "Places", "Shortcut to Routes \u{203A} Places")
            ]),
            SettingGroup("Data and backup", [
                SettingRow("data.rawRetention", "Keep raw data", RawRetention.default.rawValue),
                SettingRow("backup.folder", "Backup folder \u{00B7} Last backup", "Folder picked once"),
                SettingRow("backup.restore", "Restore", "Merges by ride"),
                SettingRow("data.export", "Export everything", "Export sheet"),
                SettingRow("data.deleteAll", "Delete all data", "Confirm sheet (backups are kept)")
            ], footer: "Raw scooter packets older than this are deleted; ride summaries, routes and the energy readings are kept."),
            SettingGroup("Help", [
                SettingRow("help.report", "Report a problem", "Log + app state + note")
            ]),
            SettingGroup("Developer", [
                SettingRow("developer.recorder", "Developer", "Checks, results and test tools")
            ])
        ]
    }

    public static func row(_ id: String) -> SettingRow? {
        groups.flatMap(\.rows).first { $0.id == id }
    }

    /// Charger choices (A) in the picker
    public static let chargerChoices: [Double] = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0]
    /// Battery size choices (Ah) in the picker
    public static let packChoices: [Double] = [16, 13]
}
