import Foundation
import Observation
import UIKit
import UserNotifications

/// The foundation's second round of on-device checks (owner's list, 4 Oct 2026):
/// c5 wake after a phone restart · c6 notification on a scooter wake · c7 Low Power Mode ·
/// b8 stable for 10 min · b9 out of range and back. Fed by AppModel's scooter handlers.
@Observable
final class FieldChecks: NSObject {
    static let shared = FieldChecks()

    // b8
    private(set) var stabilityRunning = false
    private(set) var stabilityElapsed = 0
    private(set) var stabilityDisconnects: [String] = []
    // b9
    private(set) var rangeArmed = false
    private(set) var rangeLostAt: Date?
    private(set) var rangeLog: [String] = []

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var stabilityTimer: Timer?
    @ObservationIgnored private var stabilityLastTick = Date()
    @ObservationIgnored private var launchedInBackground = false
    @ObservationIgnored private var firstLaunchSinceBoot: Bool?
    @ObservationIgnored private var wakeAt: Date?
    @ObservationIgnored private var lowPowerWake: (packets: Int, fixes: Int)?
    @ObservationIgnored private var wakeNotificationPending = false
    @ObservationIgnored private var lastWakeNotification: Date?
    static let wakeNotificationID = "corckie.test.goingForARide"

    // MARK: Launch

    /// At launch (before the data is readable): remember how the app was started.
    func appLaunched() {
        launchedInBackground = UIApplication.shared.applicationState == .background
        UNUserNotificationCenter.current().delegate = self
    }

    /// When the files are readable (after the first unlock following a restart).
    func dataAvailable() {
        if firstLaunchSinceBoot == nil {
            let boot = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
            let stored = defaults.object(forKey: "corckie.lastBootSeen") as? Date
            firstLaunchSinceBoot = stored.map { abs($0.timeIntervalSince(boot)) > 120 } ?? false
            defaults.set(boot, forKey: "corckie.lastBootSeen")
        }
        evaluateRestartWake()
        checkDeliveredNotification()
    }

    // MARK: Scooter events

    func scooterConnected(inBackground: Bool) {
        if inBackground {
            wakeAt = Date()
            evaluateRestartWake()
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                lowPowerWake = (AppModel.shared.scooter.packetsInBackground, PhoneSensors.shared.fixesInBackground)
            }
            if lastWakeNotification.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                wakeNotificationPending = true
            }
        }
        if let lost = rangeLostAt {
            let seconds = Int(Date().timeIntervalSince(lost))
            let line = "Back in range: reconnected after \(seconds) s\(inBackground ? " without opening the app" : " (app open)")"
            rangeLog.append(line)
            CheckResults.shared.set("b9", inBackground ? .pass : .info, line)
            rangeLostAt = nil
            rangeArmed = false
        }
    }

    func scooterDisconnected(reason: String) {
        if stabilityRunning {
            stabilityDisconnects.append("\(stabilityElapsed) s: \(reason)")
        }
        if rangeArmed, rangeLostAt == nil {
            rangeLostAt = Date()
            rangeLog.append("Out of range at \(Date().formatted(date: .omitted, time: .standard)) · \(reason)")
        }
    }

    func packet(batteryPct: Int?) {
        let link = AppModel.shared.scooter
        if wakeNotificationPending, UIApplication.shared.applicationState == .background, let pct = batteryPct {
            wakeNotificationPending = false
            sendWakeNotification(batteryPct: pct)
        }
        if let start = lowPowerWake, ProcessInfo.processInfo.isLowPowerModeEnabled {
            let packets = link.packetsInBackground - start.packets
            let fixes = PhoneSensors.shared.fixesInBackground - start.fixes
            if packets >= 20 && fixes >= 5 {
                CheckResults.shared.passOnce("c7", "Low Power Mode on: woke, \(packets) packets and \(fixes) fixes while locked")
                lowPowerWake = nil
            }
        }
    }

    // MARK: c5

    private func evaluateRestartWake() {
        guard let wake = wakeAt, launchedInBackground, firstLaunchSinceBoot == true else { return }
        CheckResults.shared.passOnce("c5", "After a phone restart the scooter woke the app at \(wake.formatted(date: .omitted, time: .shortened)), before you opened it")
    }

    // MARK: c6 (a test of the "Going for a ride?" chain, not the feature)

    private func sendWakeNotification(batteryPct: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async {
                    CheckResults.shared.set("c6", .fail, "Notifications aren't allowed · Permissions → allow them")
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Scooter on · \(batteryPct)%"
            content.body = "test: going for a ride?"
            content.sound = nil                     // silent
            content.interruptionLevel = .passive
            let request = UNNotificationRequest(identifier: Self.wakeNotificationID, content: content, trigger: nil)
            center.add(request) { error in
                DispatchQueue.main.async {
                    if let error {
                        CheckResults.shared.set("c6", .fail, "Couldn't send: \(error.localizedDescription)")
                    } else {
                        self.lastWakeNotification = Date()
                        Log.info(source: "notify", "Wake test notification sent (\(batteryPct)%)")
                        self.checkDeliveredNotification()
                    }
                }
            }
        }
    }

    /// ✅ when iOS lists it as delivered (checked after sending and at every app open).
    func checkDeliveredNotification() {
        UNUserNotificationCenter.current().getDeliveredNotifications { list in
            guard list.contains(where: { $0.request.identifier == Self.wakeNotificationID }) else { return }
            DispatchQueue.main.async {
                if CheckResults.shared.status("c6") != .pass {
                    CheckResults.shared.set("c6", .pass, "Delivered on a scooter wake (silent)")
                }
            }
        }
    }

    // MARK: b8

    func startStabilityTest() {
        stabilityTimer?.invalidate()
        stabilityRunning = true
        stabilityElapsed = 0
        stabilityDisconnects = []
        stabilityLastTick = Date()
        CheckResults.shared.set("b8", .pending, "Running… keep the app open, scooter on")
        stabilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.stabilityTick() }
    }

    func stopStabilityTest() {
        stabilityTimer?.invalidate()
        stabilityRunning = false
        CheckResults.shared.set("b8", .pending, "Stopped after \(stabilityElapsed) s")
    }

    private func stabilityTick() {
        let now = Date()
        let gap = now.timeIntervalSince(stabilityLastTick)
        stabilityLastTick = now
        if UIApplication.shared.applicationState != .active || gap > 3 {
            stabilityTimer?.invalidate()
            stabilityRunning = false
            CheckResults.shared.set("b8", .pending, "Interrupted: the app left the screen after \(stabilityElapsed) s · start again")
            return
        }
        stabilityElapsed += 1
        if stabilityElapsed >= 600 {
            stabilityTimer?.invalidate()
            stabilityRunning = false
            if stabilityDisconnects.isEmpty {
                CheckResults.shared.set("b8", .pass, "10 min connected, 0 disconnects")
            } else {
                CheckResults.shared.set("b8", .fail, "\(stabilityDisconnects.count) disconnects in 10 min: " + stabilityDisconnects.joined(separator: " · "))
            }
        }
    }

    // MARK: b9

    func armRangeTest() {
        rangeArmed = true
        rangeLostAt = nil
        rangeLog.append("Armed at \(Date().formatted(date: .omitted, time: .standard)): walk away until it disconnects, then come back")
        CheckResults.shared.set("b9", .pending, "Armed · walk away with the phone, then come back")
    }
}

extension FieldChecks: UNUserNotificationCenterDelegate {
    /// c6: the owner tapped the test notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == Self.wakeNotificationID {
            DispatchQueue.main.async {
                CheckResults.shared.set("c6", .pass, "Delivered on a scooter wake and tapped by the owner")
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
