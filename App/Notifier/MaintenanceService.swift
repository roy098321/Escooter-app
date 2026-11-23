import CorckieCore
import Foundation
import UserNotifications

/// M3-06: maintenance by km. Glue between `maintenance_item` rows, the rules in CorckieCore (`Maintenance`, unit tested) and
/// a local notification. Items are created on first use with the odometer of that moment (counting starts then).
enum MaintenanceService {
    struct Row: Identifiable {
        let item: MaintenanceItem
        let status: MaintenanceStatus
        var id: String { item.id }
    }

    static func item(_ r: MaintenanceRecord) -> MaintenanceItem {
        let hint = Maintenance.defaults(odoKm: nil, nowMs: 0).first { $0.id == r.id }?.hint ?? ""
        return MaintenanceItem(id: r.id, name: r.name, hint: hint, intervalKm: r.intervalKm, intervalDays: r.intervalDays,
                               lastDoneOdoKm: r.lastDoneOdoKm, lastDoneAt: r.lastDoneAt, notifiedAt: r.notifiedAt)
    }

    static func record(_ i: MaintenanceItem) -> MaintenanceRecord {
        MaintenanceRecord(id: i.id, name: i.name, intervalKm: i.intervalKm, intervalDays: i.intervalDays,
                          lastDoneOdoKm: i.lastDoneOdoKm, lastDoneAt: i.lastDoneAt, notifiedAt: i.notifiedAt)
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// The rows for the screen (creates the defaults the first time).
    static func rows(_ db: AppDatabase) -> [Row] {
        let q = MaintenanceQueries(db)
        let odo = (try? q.odometerKm()) ?? nil
        try? q.insertMissing(Maintenance.defaults(odoKm: odo, nowMs: nowMs()).map(record))
        return ((try? q.all()) ?? []).map { r in
            let i = item(r)
            return Row(item: i, status: Maintenance.status(i, odoKm: odo, nowMs: nowMs()))
        }
    }

    /// Mark done: counting starts again from the odometer now.
    static func markDone(id: String, _ db: AppDatabase) {
        let q = MaintenanceQueries(db)
        let odo = (try? q.odometerKm()) ?? nil
        guard let r = ((try? q.all()) ?? []).first(where: { $0.id == id }) else { return }
        try? q.save(record(Maintenance.markedDone(item(r), odoKm: odo, nowMs: nowMs())))
    }

    /// After a ride ends: remind about the items that are due (once, again after 3 days), within the message budget.
    static func checkAtRideEnd(_ db: AppDatabase?, rideActive: Bool = false) {
        guard let db, NotifyPrefs.isOn(db, .maintenance) else { return }
        let q = MaintenanceQueries(db)
        let now = nowMs()
        let offset = TimeZone.current.secondsFromGMT() / 60
        let odo = (try? q.odometerKm()) ?? nil
        let items = rows(db).map(\.item)
        var sent = NotificationPlanner.sentToday(db, nowMs: now, utcOffsetMin: offset)
        let weeklyDue = NotificationPlanner.weeklyDueToday(db, nowMs: now, utcOffsetMin: offset)   // M4-04: the weekly summary keeps its place
        for item in Maintenance.toRemind(items, odoKm: odo, nowMs: now) {
            switch Maintenance.decide(nowMs: now, utcOffsetMin: offset, rideActive: rideActive, sentToday: sent, weeklyDueToday: weeklyDue) {
            case .drop(let reason):
                Notifier.shared.log(MessageLogEntry(type: Maintenance.messageType, channel: "notification", at: Double(now) / 1000, droppedReason: reason))
            case .send:
                sent += 1
                send(item, status: Maintenance.status(item, odoKm: odo, nowMs: now))
                var done = item
                done.notifiedAt = now
                try? q.save(record(done))
                Notifier.shared.log(MessageLogEntry(type: Maintenance.messageType, channel: "notification", at: Double(now) / 1000, droppedReason: nil))
            }
        }
    }

    private static func send(_ item: MaintenanceItem, status: MaintenanceStatus) {
        let text = Maintenance.text(item, status: status)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "maintenance_\(item.id)", content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
        }
    }
}

// MARK: N10-13 (batch 10): the Maintenance screen's parts list

extension MaintenanceService {
    static let logKey = "maint.log"

    /// The model name and km for the header
    static func header(_ db: AppDatabase) -> String {
        let name = ScooterRecord.latest(in: db)?.name ?? "Your scooter"
        let odo = (try? MaintenanceQueries(db).odometerKm()) ?? nil
        return odo.map { "\(name) \u{00B7} \(Int($0.rounded()).formatted()) km" } ?? name
    }

    static func scooterId(_ db: AppDatabase) -> String { ScooterRecord.latest(in: db)?.id ?? "scooter" }

    /// "Health 94% · about 36 km per charge" (nil until the battery report has a number)
    static func batteryLine(_ db: AppDatabase) -> String? {
        switch BatteryOverview.load(db, currentPct: nil, connected: false).health {
        case .health(let pct, let km, _): return "Health \(Int(pct.rounded()))% \u{00B7} about \(Int(km.rounded())) km per charge"
        case .baseline(let km): return "About \(Int(km.rounded())) km per charge"
        case .gathering: return nil
        }
    }

    static func parts(_ db: AppDatabase) -> [PartRow] {
        let id = scooterId(db)
        let reminders = rows(db).compactMap { r -> PartReminder? in
            guard let part = PartReminder.part(forReminder: r.id) else { return nil }
            return PartReminder(id: r.id, part: part, status: r.status, name: r.item.name)
        }
        let book = FaultStore.load(db, FaultStore.bookKey, as: FaultBook.self) ?? FaultBook()
        var left: [MaintPart: Int] = [:]
        for p in MaintPart.allCases { left[p] = MaintParts.ridesLeft(book, scooterId: id, part: p) }
        return MaintParts.rows(open: FaultRecord.open(FaultStore.records(db), scooterId: id), reminders: reminders, ridesLeft: left,
                               batteryLine: batteryLine(db), hints: EnergyHintService.hints(db))   // N11-1
    }

    static func logged(_ db: AppDatabase?) -> [LoggedWork] { FaultStore.load(db, logKey, as: [LoggedWork].self) ?? [] }

    /// "Log what I did": one tap. The km comes from the scooter; the part's reminder restarts; a replaced part relearns (A30).
    static func log(_ what: LogWhatIDid, _ db: AppDatabase) {
        let id = scooterId(db)
        let odo = (try? MaintenanceQueries(db).odometerKm()) ?? nil
        var list = logged(db)
        list.append(LoggedWork(what: what, scooterId: id, day: FaultGate.day(epochMs: nowMs()), odoKm: odo))
        FaultStore.save(db, logKey, list)
        if let r = what.reminderId { markDone(id: r, db) }
        if what.relearns { FaultStore.partServiced(what.part, scooterId: id, db) }
        if what == .replacedTyre || what == .replacedBattery { EnergyHintService.reset(db) }   // N11-1: a new normal
        Log.info(source: "maintenance", "Logged: \(what.title)")
    }

    /// Reminder page: change the interval, or switch it off (nil)
    static func setInterval(id: String, km: Double?, _ db: AppDatabase) {
        let q = MaintenanceQueries(db)
        guard var r = ((try? q.all()) ?? []).first(where: { $0.id == id }) else { return }
        r.intervalKm = km
        if km == nil { r.intervalDays = nil }
        try? q.save(r)
    }
}
