import CoreLocation
import CorckieCore
import Foundation
import GRDB
import UIKit

/// B81 (hotfix 103.081126.02): the 30-day diary. One line per event in a file per day, so it survives the app being closed by iOS
/// (the in-memory Bluetooth events and the 15-minute logs do not). What goes in:
/// - app: launch (and why: iOS relaunch for the scooter), foreground / background, terminate, memory warning, data locked / unlocked,
///   iOS reports (MetricKit crashes and background exit reasons)
/// - bluetooth: every ScooterLink event (scan, connect, disconnect with reason, iOS restore)
/// - ride: every Recorder line (ride started, really riding, confirmed, dropped and why, phone took over, closed)
/// - phone: location permission, Low Power Mode, Background App Refresh, Bluetooth state (written when it changes)
/// - log: every app log line (warnings and errors too); voice: every line spoken; notification: every ride notification
/// Nothing leaves the phone unless the rider shares Export log. Cleaned once a day (LogRetention).
final class Diary {
    static let shared = Diary()

    private let queue = DispatchQueue(label: "corckie.diary")
    /// Lines waiting while files can't be written (before the first unlock after a restart)
    private var pending: [String] = []
    private var lastPhoneState = ""
    private var started = false
    /// G2 margin: a runaway logger can't fill the phone; a day stops at 4 MB (the rest of that day is counted, not written)
    static let maxBytesPerDay = 4 * 1_024 * 1_024
    private var skippedToday = 0

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("diary", isDirectory: true)
    }

    static func dayFile(_ date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return folder.appendingPathComponent("diary-\(f.string(from: date)).log")
    }

    // MARK: writing

    func note(_ kind: String, _ text: String) {
        let line = DiaryLine(atMs: Int64(Date().timeIntervalSince1970 * 1000), kind: kind, text: text).encoded + "\n"
        queue.async { self.write(line) }
    }

    private func write(_ line: String) {
        pending.append(line)
        if pending.count > 5_000 { pending.removeFirst(pending.count - 5_000) }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let url = Self.dayFile(Date())
            if !fm.fileExists(atPath: url.path) {
                skippedToday = 0
                fm.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > Self.maxBytesPerDay {
                skippedToday += pending.count
                pending = []
                return
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(pending.joined().utf8))
            pending = []
        } catch {
            // the file can't be written yet (locked phone after a restart): the lines wait in `pending`
        }
    }

    // MARK: reading

    /// All lines in a window (or everything), oldest first
    func lines(in window: ClosedRange<Int64>? = nil) -> [DiaryLine] {
        queue.sync { _ = 0 }   // let queued writes land first
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        var out: [DiaryLine] = []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "log" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for l in text.split(separator: "\n") {
                if let d = DiaryLine.parse(String(l)), window.map({ $0.contains(d.atMs) }) ?? true { out.append(d) }
            }
        }
        return out
    }

    func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: app and phone events

    /// At every launch (also the background relaunch for the scooter)
    func start(relaunchedForBluetooth: Bool) {
        guard !started else { return }
        started = true
        let state = UIApplication.shared.applicationState == .background ? "in the background" : "on screen"
        note("app", "Launch \(AppInfo.versionLine) \(state)" + (relaunchedForBluetooth ? " · relaunched by iOS for the scooter" : ""))
        let nc = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "Foreground"),
            (UIApplication.didEnterBackgroundNotification, "Background"),
            (UIApplication.willTerminateNotification, "Closing (iOS or swiped away)"),
            (UIApplication.didReceiveMemoryWarningNotification, "Memory warning"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "Phone locked (files locked)"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "Phone unlocked")
        ]
        for (name, text) in events {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Diary.shared.note("app", text)
                Diary.shared.notePhoneState()
            }
        }
        nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in Diary.shared.notePhoneState() }
        nc.addObserver(forName: UIApplication.backgroundRefreshStatusDidChangeNotification, object: nil, queue: .main) { _ in Diary.shared.notePhoneState() }
        DispatchQueue.main.async { Diary.shared.notePhoneState() }
    }

    /// Location / Low Power Mode / Background App Refresh / Bluetooth, written only when something changed
    func notePhoneState() {
        let s = Self.phoneState()
        guard s != lastPhoneState else { return }
        lastPhoneState = s
        note("phone", s)
    }

    static func phoneState() -> String {
        let loc: String
        switch PermissionsCheck.shared.locationStatus {
        case .authorizedAlways: loc = "Always"
        case .authorizedWhenInUse: loc = "While Using"
        case .denied: loc = "Off"
        case .restricted: loc = "Restricted"
        default: loc = "Not asked"
        }
        let refresh: String
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: refresh = "on"
        case .denied: refresh = "off"
        default: refresh = "restricted"
        }
        return "Location \(loc) · Low Power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off") · Background App Refresh \(refresh) · Bluetooth \(AppModel.shared.scooter.state)"
    }

    var locationAlways: Bool { PermissionsCheck.shared.locationStatus == .authorizedAlways }

    // MARK: cleaning (once a day)

    func cleanIfDue(_ db: AppDatabase?) {
        let key = "corckie.diary.cleanedAt"
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: key) >= 86_400 else { return }
        UserDefaults.standard.set(now, forKey: key)
        clean(db, nowMs: Int64(now * 1000))
    }

    func clean(_ db: AppDatabase?, nowMs: Int64) {
        let fm = FileManager.default
        let diaryCut = LogRetention.cutoffMs(nowMs: nowMs, days: LogRetention.diaryDays)
        var removed = 0
        for f in files() {
            let modified = (try? fm.attributesOfItem(atPath: f.path)[.modificationDate] as? Date) ?? Date()
            if Int64(modified.timeIntervalSince1970 * 1000) < diaryCut { try? fm.removeItem(at: f); removed += 1 }
        }
        removed += MissedRideReports.clean(nowMs: nowMs)
        var rows = 0
        if let db, !db.isReadOnly {
            let errCut = LogRetention.cutoffMs(nowMs: nowMs, days: LogRetention.errorLogDays)
            let msgCut = LogRetention.cutoffMs(nowMs: nowMs, days: LogRetention.messageLogDays)
            try? db.writer.write { d in
                try d.execute(sql: "DELETE FROM error_log WHERE at < ?", arguments: [errCut])
                rows += d.changesCount
                try d.execute(sql: "DELETE FROM message_log WHERE COALESCE(sentAt, scheduledFor, 0) < ? AND COALESCE(sentAt, scheduledFor) IS NOT NULL", arguments: [msgCut])
                rows += d.changesCount
            }
        }
        if removed + rows > 0 { note("app", "Cleaned old logs: \(removed) files, \(rows) rows") }
    }
}
