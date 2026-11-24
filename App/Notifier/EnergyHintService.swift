import CorckieCore
import Foundation
import GRDB

/// N11-1 · E4 tyre-pressure hint, app side: after every ride the ride's numbers go into `EnergyHint` (Core); the step it is in
/// lights the Tyres (or Brakes / Motor) tile through `MaintParts.rows(hints:)` and the part page shows the optional taps.
/// Stored per scooter in `setting` "tyre.energyBook" (everything stays on the phone, P-2). A borrowed scooter is skipped.
enum EnergyHintService {
    static func book(_ db: AppDatabase?) -> EnergyBook { FaultStore.load(db, EnergyBook.settingKey, as: EnergyBook.self) ?? EnergyBook() }
    static func save(_ db: AppDatabase?, _ b: EnergyBook) { FaultStore.save(db, EnergyBook.settingKey, b) }

    /// Called from FaultService.rideClosed (background queue) with the ride's decoded frames
    static func rideClosed(ride: RideRecord, frames: [ScooterFrame], samples: [RideSampleRecord], scooterId: String, firmware: String?,
                           db: AppDatabase) {
        guard !db.isReadOnly, !GarageService.activeIsBorrowed(db), ride.kind == "ride",
              let meters = ride.distanceM, let wh = ride.energyWhRaw else { return }
        let extra = try? db.writer.read { d in
            try Row.fetchOne(d, sql: "SELECT routeId, airTempC, headwindKmh, wet, wetOverride FROM ride WHERE id = ?", arguments: [ride.id])
        }
        let km = meters / 1000
        let gears = frames.compactMap(\.gear)
        let mainGear = Dictionary(grouping: gears, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        // B111 (hotfix .11): `wet` is TEXT ("dry" / "rain" …); reading it as Int trapped in GRDB and crashed every ride close
        let wet = EnergyHint.isWet(override: extra?["wetOverride"] as String?, weather: extra?["wet"] as String?)
        let input = EnergyRide(rideId: ride.id, day: FaultGate.day(epochMs: ride.startAt), routeId: extra?["routeId"], distanceKm: km,
                               energyWh: wh, airTempC: extra?["airTempC"], headwindKmh: extra?["headwindKmh"], wet: wet,
                               avgKmh: ride.avgMovingMps.map { $0 * 3.6 }, stopsPerKm: ride.stops.map { km > 0 ? Double($0) / km : 0 },
                               mainGear: mainGear, gapS: max(ride.gapScooterS ?? 0, ride.gapGpsS ?? 0),
                               wheelOverGps: FaultService.wheelGpsRatio(samples), pull: LoadEstimate.pull(points(frames)),
                               motorRiseC: ride.tempRiseC, firmware: firmware)
        var b = book(db)
        let packWh = CalibrationUpdater.current(db).usableWh
        let out = EnergyHint.ride(&b, scooterId: scooterId, input, packWh: packWh > 0 ? packWh : nil)
        save(db, b)
        Log.info(source: "tyre", "E4: \(out.skipped.map { "skipped (\($0.rawValue))" } ?? String(format: "ratio %.3f", out.ratio ?? 0)) \u{00B7} \(out.stepBefore.rawValue) -> \(out.stepAfter.rawValue)")
    }

    /// 1-s readings (speed, volts × amps) for the load estimate
    static func points(_ frames: [ScooterFrame]) -> [LoadEstimate.Point] {
        var out: [LoadEstimate.Point] = []
        var lastSecond = -1
        for f in frames {
            let sec = Int(f.t)
            guard sec != lastSecond, let kmh = f.speedKmh, let v = f.voltage, let a = f.currentA else { continue }
            lastSecond = sec
            out.append(LoadEstimate.Point(t: f.t, speedMps: kmh / 3.6, powerW: v * a))
        }
        return out
    }

    /// The hint for the active scooter, if it should light a tile (the "watching" step stays quiet, P-7)
    static func current(_ db: AppDatabase?) -> (step: EnergyStep, text: EnergyCopy.Text)? {
        guard let db, !GarageService.activeIsBorrowed(db) else { return nil }
        let id = MaintenanceService.scooterId(db)
        guard let s = book(db).scooters[id], s.step != .quiet, s.step != .pumped else { return nil }
        let model = GarageService.registry(db).scooter(id)?.model ?? ScooterRecord.latest(in: db)?.name
        guard let text = EnergyCopy.text(s.step, tyre: KnownScooters.tyre(model: model), motorHot: s.motorHot) else { return nil }
        return (s.step, text)
    }

    /// Part rows: one line per lit part
    static func hints(_ db: AppDatabase?) -> [MaintPart: String] {
        guard let c = current(db) else { return [:] }
        return [c.text.part: c.text.row]
    }

    static func tap(_ tap: EnergyHint.Tap, _ db: AppDatabase) {
        var b = book(db)
        EnergyHint.tap(&b, scooterId: MaintenanceService.scooterId(db), tap)
        save(db, b)
        // "Checked, pressure is fine" goes into the service book (date + km), like Log what I did
        if tap == .pressureFine || tap == .pumped { MaintenanceService.log(.tyrePressure, db) }
    }

    /// "Back to normal: +1.5 km of range", once (shown on the Tyres page)
    static func takeBackToNormal(_ db: AppDatabase) -> String? {
        var b = book(db)
        let line = EnergyHint.takeBackToNormal(&b, scooterId: MaintenanceService.scooterId(db))
        if line != nil { save(db, b) }
        return line
    }

    /// A replaced battery or tyre, a firmware change (handled in Core) or Start fresh: a new normal for this scooter
    static func reset(_ db: AppDatabase) {
        var b = book(db)
        EnergyHint.reset(&b, scooterId: MaintenanceService.scooterId(db))
        save(db, b)
    }
}
