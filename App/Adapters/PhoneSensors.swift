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
    /// c8: when the current recording started (for the timer on the Sensors screen)
    private(set) var recordingSince: Date?
    private(set) var longestGapS = 0.0

    private(set) var recording = false
    private(set) var fixes = 0
    private(set) var fixesInBackground = 0
    private(set) var lastFix = "—"
    private(set) var permission = "Not asked yet"
    private(set) var altitude: [AltitudeSample] = []
    /// Rounded to the 0.01° cell (~1 km) — all that outside requests may send (policy P-2, ARCHITECTURE §3)
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
            C8Recorder.shared.start()
            sessionStart = Date()
            recordingSince = sessionStart
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
                RecorderService.shared.barometer(relativeAltitudeM: data.relativeAltitude.doubleValue,
                                                 pressureKPa: data.pressure.doubleValue, at: Date())
                let background = self.inBackground
                self.altitude.append(AltitudeSample(time: Date(), meters: data.relativeAltitude.doubleValue, background: background))
                C8Recorder.shared.barometer(relativeAltitudeM: data.relativeAltitude.doubleValue,
                                            pressureKPa: data.pressure.doubleValue, at: Date())
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
        C8Recorder.shared.stop()
        updateRideCheck()
        manager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        recording = false
        sessionStart = nil
        recordingSince = nil
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
        guard let start = sessionStart, Date().timeIntervalSince(start) >= 20 * 60,
              let summary = C8Recorder.shared.summary() else { return }
        CheckResults.shared.set("c8", .info, summary)
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
        // M1-09: every fix goes to the Recorder (the ride engine filters by accuracy, T28)
        for l in locations {
            RecorderService.shared.fix(lat: l.coordinate.latitude, lon: l.coordinate.longitude, hAccM: l.horizontalAccuracy,
                                       speedMps: l.speed, courseDeg: l.course,
                                       altitudeM: l.verticalAccuracy >= 0 ? l.altitude : nil, at: l.timestamp)
        }
        roundedLocation = ((last.coordinate.latitude / 0.01).rounded() * 0.01, (last.coordinate.longitude / 0.01).rounded() * 0.01)
        guard recording else { return }
        fixes += locations.count
        locations.forEach { C8Recorder.shared.location($0) }
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
