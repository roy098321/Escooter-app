import CoreBluetooth
import CoreLocation
import CoreMotion
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// h1: every permission v1 needs (✅ only when all are allowed and location is "Always").
/// h2: notification sounds on (B10: the chime needs them).
@Observable
final class PermissionsCheck: NSObject {
    static let shared = PermissionsCheck()

    struct Item: Identifiable {
        let id: String
        let name: String
        let state: String
        let ok: Bool
    }

    enum Sounds: String {
        case on = "on"
        case off = "off → open iPhone Settings → Notifications → CorckieApp → Sounds"
        case notOffered = "not offered → open iPhone Settings → Notifications → CorckieApp"
        case unknown = "not asked yet"
    }

    private(set) var items: [Item] = []
    private(set) var sounds: Sounds = .unknown
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var notificationsAllowed = false
    var soundsOn: Bool { sounds == .on }

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let motion = CMMotionActivityManager()
    @ObservationIgnored private var askedSoundAgain = false

    override private init() {
        super.init()
        locationManager.delegate = self
    }

    /// B10: always ask for alerts, sounds and badges.
    static let notificationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]

    func refresh() {
        locationStatus = locationManager.authorizationStatus
        let location: Item = {
            switch locationStatus {
            case .authorizedAlways: return Item(id: "location", name: "Location", state: "Always", ok: true)
            case .authorizedWhenInUse: return Item(id: "location", name: "Location", state: "While using · needs Always", ok: false)
            case .denied, .restricted: return Item(id: "location", name: "Location", state: "Denied", ok: false)
            default: return Item(id: "location", name: "Location", state: "Not asked yet", ok: false)
            }
        }()
        let motionItem: Item = {
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: return Item(id: "motion", name: "Motion", state: "Allowed", ok: true)
            case .denied, .restricted: return Item(id: "motion", name: "Motion", state: "Denied", ok: false)
            default: return Item(id: "motion", name: "Motion", state: "Not asked yet", ok: false)
            }
        }()
        let bluetooth: Item = {
            switch CBManager.authorization {
            case .allowedAlways: return Item(id: "bluetooth", name: "Bluetooth", state: "Allowed", ok: true)
            case .denied, .restricted: return Item(id: "bluetooth", name: "Bluetooth", state: "Denied", ok: false)
            default: return Item(id: "bluetooth", name: "Bluetooth", state: "Not asked yet", ok: false)
            }
        }()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = [UNAuthorizationStatus.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            let sounds: Sounds
            if !allowed {
                sounds = .unknown
            } else {
                switch settings.soundSetting {
                case .enabled: sounds = .on
                case .disabled: sounds = .off
                default: sounds = .notOffered
                }
            }
            let state: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = "Allowed · Sounds: \(sounds.rawValue)"
            case .denied: state = "Denied"
            default: state = "Not asked yet"
            }
            let notifications = Item(id: "notifications", name: "Notifications", state: state, ok: allowed)
            DispatchQueue.main.async {
                self.notificationsAllowed = allowed
                self.sounds = sounds
                self.items = [location, notifications, motionItem, bluetooth]
                let missing = self.items.filter { !$0.ok }
                let note = self.items.map { "\($0.name): \($0.state)" }.joined(separator: " · ")
                CheckResults.shared.set("h1", missing.isEmpty ? .pass : .fail, note)
                if allowed {
                    CheckResults.shared.set("h2", sounds == .on ? .pass : .fail, "Sounds: \(sounds.rawValue)")
                } else {
                    CheckResults.shared.set("h2", .fail, "Allow notifications first (Permissions, step 1)")
                }
                // B10: already allowed but without sound → ask again with .sound (harmless; once per launch)
                if allowed && sounds != .on && !self.askedSoundAgain {
                    self.askedSoundAgain = true
                    UNUserNotificationCenter.current().requestAuthorization(options: Self.notificationOptions) { _, _ in
                        DispatchQueue.main.async { self.refresh() }
                    }
                }
            }
        }
    }

    // MARK: The guided steps (fresh install, one pass)

    func askNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: Self.notificationOptions) { _, _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// Step 2: "Allow While Using App" (iOS asks for this first).
    func askLocationWhileUsing() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// Step 3: upgrade to "Always" (iOS shows "Change to Always Allow"; else open Settings).
    func askLocationAlways() {
        if locationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if self.locationManager.authorizationStatus != .authorizedAlways { Self.openSettings() }
            }
        } else if locationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            Self.openSettings()
        }
    }

    /// Step 4: motion (barometer) — a small activity query makes iOS ask.
    func askMotion() {
        let now = Date()
        motion.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { [weak self] _, _ in
            self?.refresh()
        }
    }

    /// Step 5: Bluetooth — starting the scooter link makes iOS ask.
    func askBluetooth() {
        AppModel.shared.scooter.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

extension PermissionsCheck: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }
}

/// Developer → Permissions (h1, h2): all four permissions in one guided pass.
struct PermissionsView: View {
    private let check = PermissionsCheck.shared
    private let results = CheckResults.shared

    var body: some View {
        List {
            Section {
                line("h1")
                line("h2")
            }
            Section {
                step(1, "Notifications (with sounds)", done: check.notificationsAllowed, action: "Allow") { check.askNotifications() }
                step(2, "Location: Allow While Using App", done: check.locationStatus == .authorizedWhenInUse || check.locationStatus == .authorizedAlways,
                     action: "Ask") { check.askLocationWhileUsing() }
                step(3, "Location: change to Always (tap \"Change to Always Allow\"; if no prompt, Settings opens → Location → Always)",
                     done: check.locationStatus == .authorizedAlways, action: "Always") { check.askLocationAlways() }
                step(4, "Motion & Fitness (barometer)", done: CMMotionActivityManager.authorizationStatus() == .authorized, action: "Allow") { check.askMotion() }
                step(5, "Bluetooth (the scooter)", done: CBManager.authorization == .allowedAlways, action: "Allow") { check.askBluetooth() }
                step(6, "Notification sounds on (for the chime)", done: check.soundsOn, action: "Settings") { PermissionsCheck.openSettings() }
            } header: {
                Text("Set up, in order")
            } footer: {
                Text("Do the steps top to bottom. If iOS doesn't show a prompt, the button opens iPhone Settings → CorckieApp.")
            }
            Section("Now") {
                ForEach(check.items) { item in
                    LabeledContent(item.name) {
                        Text("\(item.ok ? "✅" : "❌") \(item.state)").multilineTextAlignment(.trailing)
                    }
                }
                Button("Open iPhone Settings for CorckieApp") { PermissionsCheck.openSettings() }
            }
        }
        .navigationTitle("Permissions")
        .screen("Permissions")
        .onAppear { check.refresh() }
    }

    private func line(_ id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(results.status(id).icon)
            VStack(alignment: .leading) {
                Text("\(id.uppercased()) · \(CheckList.item(id)?.title ?? id)")
                if !results.note(id).isEmpty {
                    Text(results.note(id)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func step(_ n: Int, _ title: String, done: Bool, action: String, _ run: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(done ? "✅" : "\(n).").monospacedDigit().frame(width: 28, alignment: .leading)
            Text(title).font(.subheadline)
            Spacer()
            if !done {
                Button(action, action: run).buttonStyle(.bordered)
            }
        }
    }
}
