import CorckieCore
import Foundation

/// M2-05: where "the battery now" comes from for decisions on the Routes screens (greying, There and back, ride-start warning).
/// Scooter connected: the live reading. While the simulator runs: the simulated scooter's last reading. Otherwise the last
/// reading the app saw, with its age ("from 64%, 2 h ago"). Not compiled into AppTests (it needs the live app objects).
enum BatteryNowSource {
    static func current(database: AppDatabase? = AppModel.shared.displayDatabase) -> BatteryNow? {
        if ScreenSimulator.shared.active {
            if let p = RecorderService.shared.live?.batteryPct { return BatteryNow(pct: Double(p)) }
            if let db = database, let r = try? RideQueries(db).rides(limit: 1).first, let rest = r.endRestPct { return BatteryNow(pct: rest) }
            return nil
        }
        let scooter = AppModel.shared.scooter
        if scooter.connected, let p = scooter.frame?.batteryPct { return BatteryNow(pct: Double(p)) }
        let seen = LastSeen.load()
        guard let ms = seen.ms, let pct = seen.pct else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return BatteryNow(pct: Double(pct), ageMin: Int(max(0, nowMs - ms) / 60_000))
    }
}
