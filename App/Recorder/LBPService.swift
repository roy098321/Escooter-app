import CorckieCore
import Foundation
import GRDB

/// LBP (batch 102): learns, per scooter, where the power starts to be held back, from the real rides that went below 15 % (Core
/// `LowBatteryPower`); kept in UserDefaults per scooter id. Before such a ride nothing is learned and nothing changes.
enum LBPService {
    /// The learned limit of the scooter in use (nil = not learned)
    static func current(_ db: AppDatabase) -> LBPLearned? {
        guard let id = ScooterRecord.latest(in: db)?.id else { return nil }
        return LowBatteryPower.parse(UserDefaults.standard.data(forKey: LowBatteryPower.key(scooterId: id)))
    }

    /// Re-learns from the deep rides (cheap when there are none); called when the Battery page opens and after a ride
    @discardableResult
    static func update(_ db: AppDatabase) -> LBPLearned? {
        guard let id = ScooterRecord.latest(in: db)?.id else { return nil }
        let rows = (try? db.writer.read { d in
            try Row.fetchAll(d, sql: """
                SELECT s.batteryPct AS b, COALESCE(s.powerW, s.voltage * s.currentA) AS p FROM ride_sample s JOIN ride r ON r.id = s.rideId
                WHERE r.isSimulated = 0 AND (r.scooterId = ? OR r.scooterId IS NULL) AND s.batteryPct IS NOT NULL
                  AND s.rideId IN (SELECT DISTINCT rideId FROM ride_sample WHERE batteryPct < ?)
                """, arguments: [id, LowBatteryPower.deepPct])
        }) ?? []
        let samples = rows.compactMap { r -> LBPSample? in
            guard let b: Int = r["b"], let p: Double = r["p"] else { return nil }
            return LBPSample(batteryPct: b, powerW: p)
        }
        let learned = LowBatteryPower.learn(samples)
        let key = LowBatteryPower.key(scooterId: id)
        if let l = learned, let data = LowBatteryPower.json(l) { UserDefaults.standard.set(data, forKey: key) }
        return learned ?? current(db)
    }
}
