import CorckieCore
import SwiftUI
import UserNotifications

/// I2: Battery → Measure charging speed. Optional, by choice. While the scooter charges, a reminder every 20 minutes asks for the
/// battery % shown on the scooter's screen. Two or more entries give the speed, which then replaces the learned value.
enum ChargeSpeedStore {
    static let entriesKey = "charge.measure.entries"
    static let rateKey = "charge.measuredRate"
    static let reminderId = "charge_measure"

    static func entries(_ db: AppDatabase?) -> [ChargeSpeedMeasure.Entry] {
        ChargeSpeedMeasure.decode(SettingsValue.text(db, entriesKey))
    }

    /// The measured speed in % per hour, when the rider measured one
    static func measuredRate(_ db: AppDatabase?) -> Double? { SettingsValue.number(db, rateKey) }

    static func add(_ db: AppDatabase?, pct: Double, nowMs: Int64) {
        var list = entries(db)
        list.append(.init(atMs: nowMs, pct: pct))
        SettingsValue.set(db, entriesKey, ChargeSpeedMeasure.encode(list))
        if let rate = ChargeSpeedMeasure.rate(list) { SettingsValue.set(db, rateKey, String(rate)) }
    }

    static func startNewMeasurement(_ db: AppDatabase?) {
        SettingsValue.set(db, entriesKey, "")
    }

    static func scheduleReminders() {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Charging speed"
        content.body = "What does the scooter's screen say now? Add the battery %."
        content.sound = .default
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: reminderId, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: ChargeSpeedMeasure.reminderEverySeconds, repeats: true)))
    }

    static func stopReminders() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderId])
    }
}

struct ChargeSpeedView: View {
    @State private var entries: [ChargeSpeedMeasure.Entry] = []
    @State private var text = ""
    @State private var reminding = false
    @State private var rate: Double?

    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        List {
            Section {
                Text("While the scooter charges, type the battery % from its screen every 20 minutes. Two entries at least 20 minutes apart are enough. You can stop at any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let rate {
                    LabeledContent("Your charging speed", value: String(format: "%.1f %% per hour", rate))
                }
            }
            .glassRows()
            Section {
                TextField("Battery % now", text: $text).keyboardType(.numberPad)
                Button("Add") { add() }
                    .disabled(ChargeSpeedMeasure.validPct(text) == nil)
                Button(reminding ? "Stop reminders" : "Remind me every 20 min") { toggleReminders() }
                if !entries.isEmpty {
                    Button("Start a new measurement", role: .destructive) {
                        ChargeSpeedStore.startNewMeasurement(db)
                        reload()
                    }
                }
            }
            .glassRows()
            if !entries.isEmpty {
                GlassSection("Entries") {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        LabeledContent(Date(timeIntervalSince1970: Double(e.atMs) / 1000).formatted(date: .omitted, time: .shortened),
                                       value: "\(Int(e.pct)) %")
                    }
                }
                .glassRows()
            }
        }
        .glassList()
        .navigationTitle("Charging speed")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .screen("Charging speed")
    }

    private func reload() {
        entries = ChargeSpeedStore.entries(db)
        rate = ChargeSpeedStore.measuredRate(db)
    }

    private func add() {
        guard let pct = ChargeSpeedMeasure.validPct(text) else { return }
        ChargeSpeedStore.add(db, pct: pct, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        text = ""
        reload()
    }

    private func toggleReminders() {
        if reminding {
            ChargeSpeedStore.stopReminders()
        } else {
            UNUserNotificationCenter.current().requestAuthorization(options: PermissionsCheck.notificationOptions) { _, _ in
                DispatchQueue.main.async { ChargeSpeedStore.scheduleReminders() }
            }
        }
        reminding.toggle()
    }
}
