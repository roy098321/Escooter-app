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

    /// `batteryPct`: only from a packet A of this connection (B27: never the value seen before the switch-off)
    func packet(batteryPct: Int?, shuttingDown: Bool) {
        let t = now()
        if shuttingDown {
            core.powerOff(at: t)
            return
        }
        core.packet(at: t)
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
        // F-36: "Scooter on" carries the destination buttons (F-39: "Continue to ..." first), made from the places as they are now
        let scooterOn = id == GoingForARideContent.notificationID
        if scooterOn { center.setNotificationCategories([Self.scooterOnCategory()]) }
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
            content.interruptionLevel = .active   // B36: passive is delivered silently
            if scooterOn { content.categoryIdentifier = ScooterOnActions.categoryId }
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

    // MARK: F-36 destination buttons

    /// The buttons: the quick-dial places (not the one the phone is in), "Continue to ..." first after a trip that did not arrive (F-39),
    /// and No destination. A button sets the destination without opening the app.
    static func destinationActions() -> [ScooterOnActions.Action] {
        guard let db = AppModel.shared.displayDatabase else { return ScooterOnActions.actions(continueTo: nil, places: []) }
        let phone = PhoneSensors.shared.lastKnown.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        let items = QuickDialLoader.load(database: db, routeChips: RouteFollowLoader.chips(database: db, log: false),
                                         slots: QuickDial.slotCount(accessibilitySize: false), from: phone).items.filter { !$0.here }
        let trip = TripService.shared.offer
        let resume = trip.map { ScooterOnActions.Place(key: QuickDialLoader.placePrefix + $0.placeId, name: $0.placeName, placeId: $0.placeId) }
        return ScooterOnActions.actions(continueTo: resume, continueTitle: trip.map(TripRules.continueText),
                                        places: items.map { ScooterOnActions.Place(key: $0.key, name: $0.name, placeId: $0.id) })
    }

    private static func scooterOnCategory() -> UNNotificationCategory {
        let actions = destinationActions().map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) }
        return UNNotificationCategory(identifier: ScooterOnActions.categoryId, actions: actions, intentIdentifiers: [], options: [])
    }

    /// A button of the "Scooter on" notification was tapped (main thread). During a ride that already started it switches like a pick at a stop.
    func destinationPicked(_ choice: ScooterOnActions.Choice) {
        let key: String?
        switch choice {
        case .destination(let k): key = k
        case .noDestination: key = nil
        case .continueTrip(let k): key = k
        }
        if RecorderService.shared.rideActive {
            RecorderService.shared.changeDestination(key)
        } else if case .continueTrip = choice {
            TripService.shared.continueTapped()
        } else {
            if key != RouteFollowSelection.shared.chosenKey { RouteFollowSelection.shared.choose(key: key) }
            TripService.shared.picked(key: RouteFollowSelection.shared.chosenKey)     // F-39: another destination closes the open trip
        }
        Log.info(source: "notify", "F-36: destination from the notification: \(key == nil ? "none" : (QuickDialLoader.placeId(fromKey: key) == nil ? "a route" : "a place"))")
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
