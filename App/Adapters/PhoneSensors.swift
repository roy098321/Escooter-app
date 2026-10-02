import CoreLocation
import CoreMotion
import Foundation
import Observation
import UIKit

/// PhoneSensors · ARCHITECTURE §2.2 #4, §5.1: location and barometer (proven in P2 D05 / D07).
/// The foundation build records them for the background checks and the arch-bridge chart;
/// the P5 recorder takes them over.
@Observable
final class PhoneSensors: NSObject {
    static let shared = PhoneSensors()

    struct AltitudeSample: Identifiable {
        let id = UUID()
        let time: Date
        let meters: Double
        let background: Bool
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var startedByWake = false

    private(set) var recording = false
    private(set) var fixes = 0
    private(set) var fixesInBackground = 0
    private(set) var lastFix = "—"
    private(set) var permission = "Not asked yet"
    private(set) var altitude: [AltitudeSample] = []
    /// Rounded to 0.02° (~2 km) — what outside requests may send (ARCHITECTURE §3)
    private(set) var roundedLocation: (lat: Double, lon: Double)?

    var altitudeInBackground: Int { altitude.filter(\.background).count }
    var altitudeRise: Double {
        let values = altitude.map(\.meters)
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    private var inBackground: Bool { UIApplication.shared.applicationState == .background }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        updatePermission()
    }

    /// Starts location (best accuracy, background allowed) and the barometer.
    func start(fromWake: Bool = false) {
        startedByWake = fromWake
        if manager.authorizationStatus == .notDetermined || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                guard let self else { return }
                if let error {
                    Log.warning(source: "barometer", error.localizedDescription)
                    return
                }
                guard let data else { return }
                let background = self.inBackground
                self.altitude.append(AltitudeSample(time: Date(), meters: data.relativeAltitude.doubleValue, background: background))
                if self.altitude.count > 20_000 { self.altitude.removeFirst(5_000) }
                if self.altitudeInBackground >= 20 {
                    CheckResults.shared.passOnce("c4", "\(self.altitudeInBackground) barometer readings while locked")
                }
            }
        }
        recording = true
    }

    /// Asks for location once, without recording (for outside-data requests).
    func requestOneFix() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        recording = false
    }

    func report() -> String {
        """
        Location: \(fixes) fixes, \(fixesInBackground) while locked · permission \(permission) · last \(lastFix)
        Barometer: \(altitude.count) readings, \(altitudeInBackground) while locked · highest − lowest \(String(format: "%.1f", altitudeRise)) m
        """
    }

    private func updatePermission() {
        switch manager.authorizationStatus {
        case .authorizedAlways: permission = "Always"
        case .authorizedWhenInUse: permission = "While using (set Always in Settings)"
        case .denied, .restricted: permission = "Denied"
        default: permission = "Not asked yet"
        }
    }
}

extension PhoneSensors: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        roundedLocation = ((last.coordinate.latitude / 0.02).rounded() * 0.02, (last.coordinate.longitude / 0.02).rounded() * 0.02)
        guard recording else { return }
        fixes += locations.count
        if inBackground {
            fixesInBackground += locations.count
            if fixesInBackground >= 20 {
                CheckResults.shared.passOnce("c3", "\(fixesInBackground) fixes while locked" + (startedByWake ? " (started by the scooter wake-up)" : ""))
            }
        }
        lastFix = last.timestamp.formatted(date: .omitted, time: .standard) + String(format: " · ±%.0f m", last.horizontalAccuracy)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.warning(source: "location", error.localizedDescription)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updatePermission()
    }
}
