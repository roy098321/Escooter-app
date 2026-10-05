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
        guard let db else { return }
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
