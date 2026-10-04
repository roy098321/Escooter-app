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
    // c8: one recording session's numbers
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var sessionFixes0 = 0
    @ObservationIgnored private var sessionAltitude0 = 0
    @ObservationIgnored private var batteryStart: Float = -1
    @ObservationIgnored private var lastPacketAt: Date?
    @ObservationIgnored private var lastSessionUpdate = Date.distantPast
    private(set) var packetGapsOver2s = 0
    private(set) var longestGapS = 0.0

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
        if !recording {
            sessionStart = Date()
            sessionFixes0 = fixes
            sessionAltitude0 = altitude.count
            packetGapsOver2s = 0
            longestGapS = 0
            lastPacketAt = nil
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryStart = UIDevice.current.batteryLevel
        }
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
        updateRideCheck()
        manager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        recording = false
        sessionStart = nil
    }

    /// c8: every scooter packet while recording (gaps > 2 s between packets).
    func notePacket(at time: Date) {
        guard recording else { return }
        if let last = lastPacketAt {
            let gap = time.timeIntervalSince(last)
            if gap > 2 {
                packetGapsOver2s += 1
                longestGapS = max(longestGapS, gap)
            }
        }
        lastPacketAt = time
        if Date().timeIntervalSince(lastSessionUpdate) > 30 { updateRideCheck() }
    }

    /// c8 ℹ️ once a recording has run 20+ minutes.
    func updateRideCheck() {
        lastSessionUpdate = Date()
        guard let start = sessionStart else { return }
        let minutes = Date().timeIntervalSince(start) / 60
        guard minutes >= 20 else { return }
        let level = UIDevice.current.batteryLevel
        let battery: String
        if batteryStart >= 0, level >= 0 {
            let used = Double(batteryStart - level) * 100
            battery = String(format: "phone battery %.0f%% used (%.1f%% per 30 min)", used, used / (minutes / 30))
        } else {
            battery = "phone battery not readable"
        }
        let note = String(format: "%.0f min · ", minutes)
            + "\(packetGapsOver2s) packet gaps > 2 s (longest \(Int(longestGapS)) s) · "
            + "\(fixes - sessionFixes0) fixes (\(fixesInBackground) while locked) · "
            + "\(altitude.count - sessionAltitude0) barometer readings · " + battery
        CheckResults.shared.set("c8", .info, note)
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
