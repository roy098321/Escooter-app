import CorckieCore
import CoreLocation
import Foundation
import Observation
import UIKit

/// B34 / B35: what the app notes on every scooter connect and disconnect, read-only (nothing is ever sent to the scooter):
/// - the phone's location, if a good fix exists (<= 50 m, <= 2 min old), as the scooter's last-seen spot, kept on the phone only (P-2);
/// - on the first packet of a connection, the odometer: it completes that spot and is compared with the odometer at the end of the last
///   recorded ride. A jump beyond 0.3 km is riding that was not recorded (`GapStore`, `OdometerGap`).
@Observable
final class ConnectionWatch {
    static let shared = ConnectionWatch()
    private static let spotKey = "corckie.lastSeenSpot"
    private static let dismissedKey = "corckie.gapDismissedToKm"

    /// bumped when a spot or a gap was saved, so Home and the Scooter tab reload
    private(set) var token = 0
    @ObservationIgnored private var odoPending = false
    @ObservationIgnored private var gapChecked = false

    private init() {}

    // MARK: Last-seen spot

    static func loadSpot() -> LastSeenSpot? {
        UserDefaults.standard.data(forKey: spotKey).flatMap { try? JSONDecoder().decode(LastSeenSpot.self, from: $0) }
    }

    private static func save(_ spot: LastSeenSpot) {
        if let data = try? JSONEncoder().encode(spot) { UserDefaults.standard.set(data, forKey: spotKey) }
    }

    /// the phone's last fix, only when it is good and fresh enough
    private func usableFix() -> CLLocation? {
        guard let l = PhoneSensors.shared.lastKnown,
              LastSeenSpot.fixUsable(accuracyM: l.horizontalAccuracy, ageS: Date().timeIntervalSince(l.timestamp)) else { return nil }
        return l
    }

    func connected() {
        gapChecked = false
        odoPending = false
        guard let l = usableFix() else {
            Log.info(source: "parked", "Connect: no good phone fix to save as the last-seen spot")
            return
        }
        Self.save(LastSeenSpot(lat: l.coordinate.latitude, lon: l.coordinate.longitude, atMs: Int64(Date().timeIntervalSince1970 * 1000), odoKm: nil))
        odoPending = true
        token += 1
    }

    func disconnected(odoKm: Double?) {
        odoPending = false
        guard let l = usableFix() else {
            Log.info(source: "parked", "Disconnect: no good phone fix to save as the last-seen spot")
            return
        }
        Self.save(LastSeenSpot(lat: l.coordinate.latitude, lon: l.coordinate.longitude, atMs: Int64(Date().timeIntervalSince1970 * 1000), odoKm: odoKm))
        token += 1
    }

    /// Every packet calls this; it does its work once per connection, on the first packet that carries the odometer.
    func packet(odoKm: Double?) {
        guard !gapChecked, let odo = odoKm, odo > 0 else { return }
        gapChecked = true
        if odoPending, var spot = Self.loadSpot(), spot.odoKm == nil {
            spot.odoKm = odo
            Self.save(spot)
        }
        odoPending = false
        guard let db = AppModel.shared.database,
              let gap = GapStore.detect(db, connectOdoKm: odo, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) else { return }
        Log.warning(source: "gap", "\(OdometerGap.homeLine(km: gap.km)) (odometer \(String(format: "%.1f", gap.fromKm)) to \(String(format: "%.1f", gap.toKm))). \(Self.lastRunInfo())")
        token += 1
    }

    // MARK: Gap banner

    /// The newest gap the owner has not dismissed
    static func visibleGap(_ database: AppDatabase) -> UntrackedGap? {
        let dismissed = UserDefaults.standard.double(forKey: dismissedKey)
        return GapStore.all(database).first { $0.toKm > dismissed }
    }

    static func dismissGaps(upTo km: Double) {
        UserDefaults.standard.set(km, forKey: dismissedKey)
    }

    /// What the app knows about how its last run ended, for the Report-a-problem zip: crash flag and exception, MetricKit reports,
    /// Bluetooth and location state, and the last Bluetooth events.
    static func lastRunInfo() -> String {
        let crash = CrashCatcher.shared
        var parts = ["Last run ended unexpectedly: \(crash.lastRunCrashed ? "yes" : "no")"]
        if let e = crash.lastException { parts.append("exception: \(e)") }
        parts.append("MetricKit reports: \(crash.metricKitReports.count)")
        let state = UIApplication.shared.applicationState
        parts.append("app now: \(state == .background ? "background" : "foreground")")
        parts.append("Bluetooth: \(AppModel.shared.scooter.state)")
        parts.append("location status: \(PermissionsCheck.shared.locationStatus.rawValue)")
        let events = AppModel.shared.scooter.events.suffix(3).joined(separator: " | ")
        if !events.isEmpty { parts.append("last Bluetooth events: \(events)") }
        return parts.joined(separator: "; ")
    }
}

/// B34: the parked spot Home and the Scooter tab show: the newest of the last ride's end and the last-seen spot
enum ParkedResolver {
    static func current(database: AppDatabase, simulated: Bool) -> ParkedSpot? {
        let ride = ParkedLoader.latest(database: database, simulated: simulated)
        if simulated { return ride }
        let scooter = AppModel.shared.scooter
        return ParkedChoice.choose(ride: ride, seen: ConnectionWatch.loadSpot(),
                                   rideEndOdoKm: ParkedLoader.latestOdoEndKm(database: database, simulated: false),
                                   currentOdoKm: scooter.connected ? scooter.frame?.odometerKm : nil)
    }
}
