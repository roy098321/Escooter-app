import BackgroundTasks
import CorckieCore
import Foundation
import UserNotifications

/// M4-04: the budgeted notifications on the notification centre: the weekly summary (Sunday 07:30, a scheduled local notification
/// rebuilt at every ride end and app open) and "wind picking up" (a background refresh about hourly: forecast, then Q15-notify).
/// The rules are Core `NotificationBudget` (shared with maintenance); the texts and counters are `NotificationPlanner`.
/// Going for a ride and the Arrive-by reminder stay outside the budget (their own senders).
enum BudgetedNotifier {
    static let weeklyId = "weekly_summary"
    static let windId = "wind_picking_up"
    static let refreshTaskId = "com.corckieapp.app.refresh"

    // MARK: Weekly

    /// Schedule (or replace) the next Sunday 07:30 summary; no text (under 2 riding days) = nothing is pending.
    static func refreshWeekly(_ db: AppDatabase?) {
        guard let db, !db.isReadOnly else { return }
        let center = UNUserNotificationCenter.current()
        NotificationPlanner.logDeliveredWeekly(db)
        let now = NotificationPlanner.nowMs()
        guard let plan = NotificationPlanner.weekly(db, nowMs: now) else {
            center.removePendingNotificationRequests(withIdentifiers: [weeklyId])
            return
        }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.userInfo = ["open": "stats", "weekStart": plan.weekStart]
            let seconds = max(1, Double(plan.fireMs - now) / 1000)
            center.add(UNNotificationRequest(identifier: weeklyId, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))) { error in
                if error == nil { NotificationPlanner.markWeeklyScheduled(db, fireMs: plan.fireMs) }
            }
        }
    }

    // MARK: Wind picking up

    /// One check: a usual ride is likely soon and the forecast headwind is up. Returns a short line for the log.
    @discardableResult
    static func windCheck(_ db: AppDatabase?, rideActive: Bool = RecorderService.shared.rideActive) -> String {
        guard let db, !db.isReadOnly else { return "no database" }
        let now = NotificationPlanner.nowMs()
        let offset = NotificationPlanner.offsetMin()
        guard let wind = NotificationPlanner.wind(db, nowMs: now, utcOffsetMin: offset) else { return "nothing to say" }
        let decision = NotificationBudget.decide(.windPickingUp, nowMs: now, utcOffsetMin: offset, rideActive: rideActive,
                                                 sentToday: NotificationPlanner.sentToday(db, nowMs: now, utcOffsetMin: offset),
                                                 weeklyDueToday: NotificationPlanner.weeklyDueToday(db, nowMs: now, utcOffsetMin: offset),
                                                 windSentToday: NotificationPlanner.windSentToday(db, nowMs: now, utcOffsetMin: offset))
        switch decision {
        case .drop(let reason):
            NotificationPlanner.logDropped(db, .windPickingUp, reason: reason, nowMs: now)
            return "dropped (\(reason))"
        case .send:
            try? InsightQueries(db).save(wind.merge)
            NotificationPlanner.logSent(db, .windPickingUp, nowMs: now)
            let content = UNMutableNotificationContent()
            content.title = wind.title
            content.body = wind.body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: windId, content: content,
                                                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
            return "sent"
        }
    }

    // MARK: Background refresh (iOS decides when; about hourly at best)

    static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { task in
            scheduleBackgroundRefresh()
            let work = Task {
                guard let db = await MainActor.run(body: { AppModel.shared.database }) else { task.setTaskCompleted(success: false); return }
                _ = await OutsideDataService.shared.runNow(database: db, reason: "background")
                windCheck(db)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
