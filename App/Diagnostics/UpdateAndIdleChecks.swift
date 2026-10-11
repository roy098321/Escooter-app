import CorckieCore
import Foundation
import UIKit

/// a9 (T-02): "Update keeps every row". The database counts its rows per table before and after the migrations of the first launch after
/// an update (`AppDatabase.updateCounts`); the check passes when no table lost rows (new tables are allowed).
enum UpdateCheck {
    private static let flagKey = "corckie.updateJustHappened"
    private static var recordedThisProcess = false

    /// Set on the first launch after an update, cleared when "Run all automatic" has finished: the Checks screen shows a block at the top of To do
    static var justUpdated: Bool {
        get { UserDefaults.standard.bool(forKey: flagKey) }
        set { UserDefaults.standard.set(newValue, forKey: flagKey) }
    }

    /// Called from `InstallChecks.run` with the launch's state; only the first call of a process counts.
    static func recordUpdate(database: AppDatabase?, reinstalled: Bool) {
        guard !recordedThisProcess, let db = database, let counts = db.updateCounts else { return }
        guard reinstalled || !db.migratedNow.isEmpty else { return }
        recordedThisProcess = true
        let verdict = UpdateCheckRules.verdict(before: counts.before, after: counts.after)
        let migrated = db.migratedNow.isEmpty ? "" : " · migrations " + db.migratedNow.joined(separator: ", ")
        CheckResults.shared.set("a9", verdict.passed ? .pass : .fail, "Updated: " + verdict.note + migrated)
        justUpdated = true
        Log.info(source: "store", "Update check a9: \(verdict.passed ? "pass" : "FAIL") · \(verdict.note)")
    }

    /// Run all automatic: a real result of an update is kept; otherwise the counting rule itself is tried on made-up counts.
    static func run() {
        let results = CheckResults.shared
        let lost = UpdateCheckRules.verdict(before: ["ride": 3, "place": 2], after: ["ride": 2, "place": 2])
        let fine = UpdateCheckRules.verdict(before: ["ride": 3], after: ["ride": 3, "prediction": 0])
        let ruleOk = !lost.passed && lost.lost == ["ride 3 -> 2"] && fine.passed && fine.newTables == ["prediction"]
        guard ruleOk else { results.set("a9", .fail, "The counting rule itself is wrong (self-test)"); return }
        if results.note("a9").hasPrefix("Updated:") { return }
        results.set("a9", .pass, "No update since this install yet · the counting rule works (a lost row is caught, a new table is allowed); it checks the real rows on the first launch after an update")
    }
}

/// Phone battery % while no ride is active (P6 idle battery check, u50). Readings come from app opens, background refresh wakes and the
/// two ends of a ride; no extra background mode. Kept as a small list in UserDefaults. Main thread only.
enum IdleBatteryLog {
    private static let key = "corckie.idleBattery"

    static func load() -> [IdleBatterySample] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([IdleBatterySample].self, from: data)) ?? []
    }

    private static func save(_ samples: [IdleBatterySample]) {
        if let data = try? JSONEncoder().encode(samples) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// An app open or a background wake. Nothing is written during a ride or before the first unlock (the list could not be read then).
    static func recordIfIdle() {
        guard !RecorderService.shared.rideActive else { return }
        record(.idle)
    }

    static func record(_ kind: IdleBatterySample.Kind, now: Date = Date()) {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        guard device.batteryLevel >= 0 else { return }
        let charging = device.batteryState == .charging || device.batteryState == .full
        let sample = IdleBatterySample(at: now.timeIntervalSince1970, pct: Double(device.batteryLevel) * 100, charging: charging, kind: kind)
        save(IdleBattery.adding(sample, to: load()))
        refreshCheck(now: now)
    }

    static func report(now: Date = Date()) -> IdleBattery.Report { IdleBattery.report(load(), now: now.timeIntervalSince1970) }

    static func text(now: Date = Date()) -> String { IdleBattery.fileText(load(), now: now.timeIntervalSince1970) }

    /// u50: pass with the rate once there are 12 h of idle data; before that it is recorded (info) with the progress.
    static func refreshCheck(now: Date = Date()) {
        let r = report(now: now)
        CheckResults.shared.set("u50", r.ready ? .pass : .info, r.text)
    }
}

/// u50 in Run all automatic: tries the rule on made-up readings, takes a reading now and reports what is known.
enum IdleBatteryCheck {
    static func run() {
        let now = 1_000_000.0
        let day = (0...20).map { IdleBatterySample(at: now - Double(20 - $0) * 3600, pct: 90 - 0.5 * Double($0), charging: false) }
        let short = Array(day.suffix(8))
        let full = IdleBattery.report(day, now: now)
        let early = IdleBattery.report(short, now: now)
        let ruleOk = abs((full.pctPerHour ?? -1) - 0.5) < 0.001 && early.pctPerHour == nil
        guard ruleOk else {
            CheckResults.shared.set("u50", .fail, "The idle battery rule itself is wrong (self-test)")
            return
        }
        IdleBatteryLog.recordIfIdle()
        IdleBatteryLog.refreshCheck()
    }
}
