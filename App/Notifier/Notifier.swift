import CorckieCore
import Foundation
import UIKit
import UserNotifications

/// M1-10: the real "Going for a ride?" notification (CONCEPT "Message budget"). The rules live in CorckieCore
/// (`GoingForARideRule`, unit tested); this class connects them to the notification centre and `message_log`.
/// Passive (no screen wake-up), plays the Kick-off chime (needs the sound permission, B10), outside the
/// message budget and quiet hours. Tapping it opens the app; the live view "Ready" state comes with M1-12.
final class Notifier: NSObject, NotificationSending, MessageLogging {
    static let shared = Notifier()

    private lazy var core = GoingForARideNotifier(sender: self, logger: self)
    private let started = Date()
    private var offTimer: Timer?
    /// Set by the ride engine (M1-03 / M1-04) when a ride is going; until then always false
    var rideActive = false
    /// Called on the main thread after iOS accepted (or refused) the notification
    var onSent: ((Error?) -> Void)?

    private func now() -> Double { Date().timeIntervalSince(started) }

    private var appActive: Bool {
        if Thread.isMainThread { return UIApplication.shared.applicationState == .active }
        return DispatchQueue.main.sync { UIApplication.shared.applicationState == .active }
    }

    // MARK: Events from the scooter link (main thread)

    func scooterConnected() {
        core.scooterConnected(at: now(), appActive: appActive, rideActive: rideActive)
    }

    func scooterDisconnected() {
        core.scooterDisconnected(at: now())
        // Best effort: while the app is alive, clear the notification once the 2 minutes are over. If iOS has
        // suspended the app by then, it clears at the next wake or app open (appBecameActive).
        offTimer?.invalidate()
        offTimer = Timer.scheduledTimer(withTimeInterval: GoingForARideRule.sessionGapS + 1, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.core.tick(at: self.now(), appActive: self.appActive, rideActive: self.rideActive)
        }
    }

    func packet(batteryPct: Int?, shuttingDown: Bool) {
        let t = now()
        if shuttingDown {
            core.powerOff(at: t)
            return
        }
        if let pct = batteryPct {
            core.batteryReading(pct: Double(pct), at: t, appActive: appActive, rideActive: rideActive)
        }
        core.tick(at: t, appActive: appActive, rideActive: rideActive)
    }

    /// Ride start stage 1 (called by the ride engine)
    func rideStarted() {
        core.rideStarted(at: now())
    }

    /// The app came to the front: ends a long disconnect (the scooter auto-off after ~5 min) so the notification goes.
    func appBecameActive() {
        core.tick(at: now(), appActive: true, rideActive: rideActive)
    }

    // MARK: NotificationSending

    func send(id: String, title: String, body: String, soundName: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async {
                    Log.info(source: "notify", "skipped (reason: not authorized)")
                    self.onSent?(NSError(domain: "Notifier", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "Notifications are not allowed"]))
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
            content.interruptionLevel = .passive
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            let soundsOn = settings.soundSetting == .enabled
            center.add(request) { error in
                DispatchQueue.main.async {
                    if let error {
                        Log.info(source: "notify", "failed: \(error.localizedDescription)")
                    } else {
                        Log.info(source: "notify", "sent (\(title), sounds \(soundsOn ? "on" : "off"))")
                    }
                    self.onSent?(error)
                }
            }
        }
    }

    func remove(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
        Log.info(source: "notify", "removed")
    }

    // MARK: MessageLogging

    func log(_ entry: MessageLogEntry) {
        if let reason = entry.droppedReason { Log.info(source: "notify", "skipped (reason: \(reason))") }
        guard let database = AppModel.shared.database else { return }
        _ = try? MessageLogQueries(database).add(type: entry.type, channel: entry.channel,
                                                 at: Int64(Date().timeIntervalSince1970 * 1000),
                                                 droppedReason: entry.droppedReason)
    }
}
