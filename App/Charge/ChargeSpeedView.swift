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
            ChargeAutoSection()      // EXPERIMENTAL (hotfix 110.221126.01): switch-on readings, no typing
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

/// EXPERIMENTAL (hotfix 110.221126.01, owner 22 Nov): charging speed from switch-on readings, no typing. Start it on the Charging
/// speed page while the scooter charges; switch the scooter on for ~15 s every 20 minutes (a reminder can ask). Each switch-on
/// gives one reading (FaultSwitchOn collects the first 20 s); 3 readings over 40+ minutes that line up give the speed, which then
/// replaces the learned one. While it runs, a switch-on does not end the charge timer. Every reading (time, %, volts) is logged and
/// kept in the settings table, so Export everything carries it for the owner's test on the new scooter. Read-only.
enum ChargeAutoStore {
    static let activeKey = "charge.auto.active"
    static let readingsKey = "charge.auto.readings"
    static let reminderId = "charge_auto"

    static func active(_ db: AppDatabase?) -> Bool { SettingsValue.flag(db, activeKey, default: false) }

    static func readings(_ db: AppDatabase?) -> [ChargeAutoMeasure.Reading] {
        FaultStore.load(db, readingsKey, as: [ChargeAutoMeasure.Reading].self) ?? []
    }

    static func start(_ db: AppDatabase?) {
        FaultStore.save(db, readingsKey, [ChargeAutoMeasure.Reading]())
        SettingsValue.setFlag(db, activeKey, true)
        UNUserNotificationCenter.current().requestAuthorization(options: PermissionsCheck.notificationOptions) { _, _ in
            DispatchQueue.main.async { scheduleReminders() }
        }
        Log.info(source: "charge", "Auto measure started")
    }

    static func stop(_ db: AppDatabase?) {
        SettingsValue.setFlag(db, activeKey, false)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderId])
        Log.info(source: "charge", "Auto measure stopped")
    }

    static func scheduleReminders() {
        let content = UNMutableNotificationContent()
        content.title = "Charging speed"
        content.body = "Switch the scooter on for 15 seconds, then off again."
        content.sound = .default
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminderId, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: ChargeSpeedMeasure.reminderEverySeconds, repeats: true)))
    }

    /// The first seconds after a switch-on (from FaultSwitchOn): one reading while measuring
    static func switchedOn(_ frames: [ScooterFrame], db: AppDatabase?) {
        guard active(db), let r = ChargeAutoMeasure.reading(frames, atMs: Int64(Date().timeIntervalSince1970 * 1000)) else { return }
        var list = readings(db)
        list.append(r)
        FaultStore.save(db, readingsKey, list)
        Log.info(source: "charge", "Auto reading \(list.count): \(Int(r.pct)) %, \(r.voltage.map { String(format: "%.2f V", $0) } ?? "no V")")
        if case .done(let rate) = ChargeAutoMeasure.result(list) {
            SettingsValue.set(db, ChargeSpeedStore.rateKey, String(rate))
            stop(db)
            let content = UNMutableNotificationContent()
            content.title = "Charging speed measured"
            content.body = String(format: "%.1f %% per hour. You can stop switching the scooter on.", rate)
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "charge_auto_done", content: content, trigger: nil))
            Log.info(source: "charge", "Auto measure done: \(rate) % per hour")
        }
    }
}

/// The Experimental section on the Charging speed page
struct ChargeAutoSection: View {
    @State private var on = false
    @State private var list: [ChargeAutoMeasure.Reading] = []
    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        Section {
            Text("No typing: while the scooter charges, switch it on for 15 seconds every 20 minutes. The app reads the battery each time. After 3 steady readings it knows your charging speed; you don't need a full charge.")
                .font(.footnote).foregroundStyle(.secondary)
            Button(on ? "Stop" : "Start (scooter plugged in)") {
                if on { ChargeAutoStore.stop(db) } else { ChargeAutoStore.start(db) }
                reload()
            }
            ForEach(Array(list.enumerated()), id: \.offset) { i, r in
                LabeledContent("Reading \(i + 1) \u{00B7} " + Date(timeIntervalSince1970: Double(r.atMs) / 1000).formatted(date: .omitted, time: .shortened),
                               value: "\(Int(r.pct)) %" + (r.voltage.map { String(format: " \u{00B7} %.2f V", $0) } ?? ""))
            }
            if !list.isEmpty {
                switch ChargeAutoMeasure.result(list) {
                case .needMore(let n): Text("\(n) more reading\(n == 1 ? "" : "s") needed (at least 40 minutes in all).").font(.footnote)
                case .notSteady: Text("The readings don't line up yet: one more, please.").font(.footnote)
                case .done(let rate): Text(String(format: "Done: %.1f %% per hour.", rate)).font(.footnote.weight(.semibold))
                }
            }
        } header: {
            Text("Experimental \u{00B7} switch-on readings")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        on = ChargeAutoStore.active(db)
        list = ChargeAutoStore.readings(db)
    }
}
