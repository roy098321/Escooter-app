import SwiftUI
import CoreLocation

// D05 (phone part): does location keep recording with the phone locked in a pocket?
final class LocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var points = 0
    @Published var backgroundPoints = 0
    @Published var lastFix = "—"
    @Published var permission = "Not asked yet"
    @Published var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        updatePermission()
    }

    func start() {
        manager.requestAlwaysAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        running = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        running = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        points += locations.count
        if UIApplication.shared.applicationState == .background {
            backgroundPoints += locations.count
        }
        if let last = locations.last {
            lastFix = last.timestamp.formatted(date: .omitted, time: .standard)
                + String(format: " · ±%.0f m", last.horizontalAccuracy)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updatePermission()
    }

    private func updatePermission() {
        switch manager.authorizationStatus {
        case .authorizedAlways: permission = "Always ✅"
        case .authorizedWhenInUse: permission = "While using · set to Always in Settings"
        case .denied, .restricted: permission = "Denied"
        default: permission = "Not asked yet"
        }
    }
}

struct LocationTestView: View {
    @StateObject private var model = LocationModel()

    var body: some View {
        List {
            Section {
                Text("Start, lock the phone, put it in your pocket and walk for 5 minutes. Then unlock: \"Recorded while locked\" should keep growing.")
                    .font(.footnote)
            }
            Section {
                LabeledContent("Permission", value: model.permission)
                LabeledContent("Points recorded", value: "\(model.points)")
                LabeledContent("Recorded while locked", value: "\(model.backgroundPoints)")
                LabeledContent("Last fix", value: model.lastFix)
            }
            Section {
                if model.running {
                    Button("Stop", role: .destructive) { model.stop() }
                } else {
                    Button("Start recording") { model.start() }
                }
            }
        }
        .navigationTitle("Background location")
    }
}
