import CoreBluetooth
import CoreLocation
import CoreMotion
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// h1: every permission v1 needs. ✅ only when all are allowed and location is "Always".
@Observable
final class PermissionsCheck {
    static let shared = PermissionsCheck()

    struct Item: Identifiable {
        let id: String
        let name: String
        let state: String
        let ok: Bool
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private let locationManager = CLLocationManager()

    func refresh() {
        let location: Item = {
            switch locationManager.authorizationStatus {
            case .authorizedAlways: return Item(id: "location", name: "Location", state: "Always", ok: true)
            case .authorizedWhenInUse: return Item(id: "location", name: "Location", state: "While using · needs Always", ok: false)
            case .denied, .restricted: return Item(id: "location", name: "Location", state: "Denied", ok: false)
            default: return Item(id: "location", name: "Location", state: "Not asked yet", ok: false)
            }
        }()
        let motion: Item = {
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: return Item(id: "motion", name: "Motion", state: "Allowed", ok: true)
            case .denied, .restricted: return Item(id: "motion", name: "Motion", state: "Denied", ok: false)
            default: return Item(id: "motion", name: "Motion", state: "Not asked yet (start Sensors once)", ok: false)
            }
        }()
        let bluetooth: Item = {
            switch CBManager.authorization {
            case .allowedAlways: return Item(id: "bluetooth", name: "Bluetooth", state: "Allowed", ok: true)
            case .denied, .restricted: return Item(id: "bluetooth", name: "Bluetooth", state: "Denied", ok: false)
            default: return Item(id: "bluetooth", name: "Bluetooth", state: "Not asked yet (open Scooter once)", ok: false)
            }
        }()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let notifications: Item
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                notifications = Item(id: "notifications", name: "Notifications", state: "Allowed", ok: true)
            case .denied:
                notifications = Item(id: "notifications", name: "Notifications", state: "Denied", ok: false)
            default:
                notifications = Item(id: "notifications", name: "Notifications", state: "Not asked yet", ok: false)
            }
            DispatchQueue.main.async {
                self.items = [location, notifications, motion, bluetooth]
                let missing = self.items.filter { !$0.ok }
                let note = self.items.map { "\($0.name): \($0.state)" }.joined(separator: " · ")
                CheckResults.shared.set("h1", missing.isEmpty ? .pass : .fail, note)
            }
        }
    }

    func askNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func askLocationAlways() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            locationManager.requestAlwaysAuthorization()
        }
    }
}

/// Developer → Permissions (h1).
struct PermissionsView: View {
    private let check = PermissionsCheck.shared
    private let results = CheckResults.shared

    var body: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(results.status("h1").icon)
                    Text("H1 · Permissions")
                }
                ForEach(check.items) { item in
                    LabeledContent(item.name) {
                        Text("\(item.ok ? "✅" : "❌") \(item.state)")
                    }
                }
            }
            Section {
                Button("Open iPhone Settings for CorckieApp") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Ask for notifications") { check.askNotifications() }
                Button("Ask for location") { check.askLocationAlways() }
            } footer: {
                Text("Location must be \"Always\" so rides record with the phone locked. Notifications are needed for \"Going for a ride?\" (c6).")
            }
        }
        .navigationTitle("Permissions")
        .screen("Permissions")
        .onAppear { check.refresh() }
    }
}
