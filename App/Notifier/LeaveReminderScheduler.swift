import CorckieCore
import Foundation
import UserNotifications

/// M2-07: the leave-by reminder (Arrive by, M29) as a local notification scheduled for the leave time. The rules (quiet hours
/// 22:00 to 07:00, never during a ride, replaced only when 2 min or more earlier, T84) are in CorckieCore (`LeaveReminder`, unit
/// tested). Arrive-by reminders are outside the 2 a day budget (CALC_SPEC 9.4) and every decision goes to `message_log`.
/// One reminder at a time (the newest Arrive by replaces the old one).
enum LeaveReminderScheduler {
    struct Stored: Codable, Equatable {
        var routeId: String
        var targetMs: Int64
        var leaveMs: Int64
    }

    static let notificationId = "leave_by"
    private static let key = "corckie.leaveReminder"

    static func stored() -> Stored? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func store(_ s: Stored?) {
        if let s, let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        center.removeDeliveredNotifications(withIdentifiers: [notificationId])
        store(nil)
    }

    private static func log(_ reason: String?) {
        Notifier.shared.log(MessageLogEntry(type: LeaveReminder.messageType, channel: "notification", at: Date().timeIntervalSince1970,
                                            droppedReason: reason))
    }

    /// `force` = the rider just picked the time / switched it on (always replaces). Without it (the card reopened, new rides changed
    /// the plan) the reminder is only replaced when the new leave time is 2 min or more earlier (T84).
    /// `done` gets one line for the card ("Reminder set for 8:21").
    static func apply(routeId: String, destination: String, plan: ArriveByPlan, force: Bool, rideActive: Bool = RecorderService.shared.rideActive,
                      utcOffsetMin: Int = TimeZone.current.secondsFromGMT() / 60, done: @escaping (String) -> Void) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        switch LeaveReminder.decide(leaveAtMs: plan.leaveAtMs, targetAtMs: plan.targetAtMs, nowMs: nowMs, utcOffsetMin: utcOffsetMin, rideActive: rideActive) {
        case .drop(let reason):
            cancel()
            log(reason)
            done("No reminder: \(reason)")
        case .send(let atMs, let held):
            let old = stored().flatMap { $0.routeId == routeId && $0.targetMs == plan.targetAtMs ? $0.leaveMs : nil }
            if !force, !LeaveReminder.shouldReplace(oldLeaveAtMs: old, newLeaveAtMs: plan.leaveAtMs) {
                done(statusText(atMs: atMs, held: held, utcOffsetMin: utcOffsetMin))
                return
            }
            let text = LeaveReminder.text(destination: destination, plan: plan, utcOffsetMin: utcOffsetMin)
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    DispatchQueue.main.async {
                        log("not authorized")
                        done("Notifications are not allowed: turn them on in iPhone Settings")
                    }
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = text.title
                content.body = text.body
                content.sound = .default
                let seconds = max(1, Double(atMs - nowMs) / 1000)
                let request = UNNotificationRequest(identifier: notificationId, content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
                center.add(request) { error in
                    DispatchQueue.main.async {
                        if let error {
                            log("failed: \(error.localizedDescription)")
                            done("Could not set the reminder")
                        } else {
                            store(Stored(routeId: routeId, targetMs: plan.targetAtMs, leaveMs: plan.leaveAtMs))
                            log(nil)
                            done(statusText(atMs: atMs, held: held, utcOffsetMin: utcOffsetMin))
                        }
                    }
                }
            }
        }
    }

    static func statusText(atMs: Int64, held: Bool, utcOffsetMin: Int) -> String {
        let clock = DayClock.clockText(minuteOfDay: DayClock.minuteOfDay(startAtMs: atMs, utcOffsetMin: utcOffsetMin))
        return held ? "Reminder held to \(clock) (quiet hours)" : "Reminder set for \(clock)"
    }
}
