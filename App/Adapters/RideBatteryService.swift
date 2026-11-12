import CorckieCore
import Foundation

/// Batch 4 (D-PR-09; B88 / B89 / B91 / B94 / B87): the ride's ONE battery level, kept once a second on the main thread by
/// `RecorderService` before the live screen is built. The dashboard, the voice (every 10 %, arrival line), and the drain warning read it.
/// It is saved every few seconds, keyed by the engine ride's start time, so a relaunch mid-ride carries on: the level is re-seeded from
/// the live reading (B94), no 10 % line is repeated, the announced destination is not said again (B87), and after "Arrived" it stays quiet.
final class RideBatteryService {
    static let shared = RideBatteryService()

    private static let key = "corckie.b4.rideBattery"
    private var state: RideBatteryLevel?
    private var whPerPct: Double?
    private var lastSaveT = 0.0
    /// The levels reached on the last tick (the voice says the lowest)
    private(set) var reachedNow: [Int] = []
    /// This ride was picked up after a relaunch (the voice skips its start line)
    private(set) var resumed = false

    private init() {}

    var level: Double? { state?.level }
    var startPct: Double? { state?.startPct }
    var announcedKey: String? { state?.announcedKey }
    var arrivedSaid: Bool { state?.arrivedSaid ?? false }

    /// Once a second while a ride is open (starting or riding). Returns the smoothed level (nil before a reading).
    @discardableResult
    func tick(_ input: LiveInput, at t: Double, database: AppDatabase?) -> Double? {
        guard let key = input.rideStartT else { return nil }
        if state?.rideKey != key {
            whPerPct = database.map { CalibrationUpdater.current($0).whPerPct }
            if let saved = Self.load(), saved.rideKey == key {
                state = saved
                state?.resumed(at: t)
                resumed = true
                Log.info(source: "voice", "Battery level picked up after a relaunch (re-seeded from the live reading)")
            } else {
                var fresh = RideBatteryLevel(rideKey: key)
                // a ride already under way when the app (re)started: its start is not known, the live reading stands in
                if (input.rideDistanceM ?? 0) >= 200 { fresh.resumed(at: t); resumed = true } else { resumed = false }
                state = fresh
            }
        }
        let live = input.scooterLinked ? input.scooterBatteryPct : nil
        reachedNow = state?.update(t: t, livePct: live, powerW: input.scooterPowerW, currentA: input.scooterCurrentA,
                                   speedKmh: input.scooterSpeedKmh ?? input.gpsSpeedKmh,
                                   whPerPct: whPerPct ?? BatteryCalibration.prior().whPerPct) ?? []
        if t - lastSaveT >= 5 { save(); lastSaveT = t }
        return input.scooterLinked ? state?.level : nil
    }

    /// N4-7: the destination line was said for this ride
    func noteAnnounced(_ key: String?) {
        state?.announcedKey = key
        save()
    }

    /// N4-10: "Arrived" was said: no more battery lines for this ride
    func noteArrived() {
        state?.arrivedSaid = true
        save()
    }

    /// The ride closed
    func end() {
        guard state != nil else { return }
        state = nil
        reachedNow = []
        resumed = false
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func save() {
        guard let s = state, let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private static func load() -> RideBatteryLevel? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RideBatteryLevel.self, from: data)
    }
}
