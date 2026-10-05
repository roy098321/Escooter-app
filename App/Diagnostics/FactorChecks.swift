import CorckieCore
import Foundation

/// u31 (M4-02): the factors engine on made-up rides (a windy commute in the ocean) in a temporary database with the real
/// tables: headwind / wet / day type / rush hour / holiday week columns, effects recovered within 10%, the gates (counts,
/// noise, rare factors pooled), pure noise shows nothing, weather missing waits (pattern W). The line ends with this
/// phone's real factor cache.
enum FactorCheck {
    static func run(real: AppDatabase?) {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u31", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        let now = FactorSamples.t0 + 60 * FactorSamples.day

        // 1. the columns and effects through the database (24 workday rides, headwind 12 / 0 / -12 km/h, rush hour +120 s)
        var columnsOk = false, effectsOk = false, explainOk = false
        var headText = "?"
        do {
            let ids = try FactorSeed.commute(temp)
            try FactorUpdater.update(temp, rideId: ids.last, nowMs: now)
            let q = FactorQueries(temp)
            if let h = try q.input(rideId: ids[0]), let t = try q.input(rideId: ids[2]) {
                columnsOk = abs((h.headwindKmh ?? 0) - 12) < 0.5 && abs((t.headwindKmh ?? 0) + 12) < 0.5 && h.wet == "dry" && h.windLevel == "light"
                    && h.dayType == "workday" && h.rushHour == true && h.holidayWeek == false
            }
            let route = FactorEffects.forRoute(temp, routeId: "seed-route")
            let head = route.first { $0.factorId == "W1" && $0.level == "head" && $0.quantity == .time }?.timeEffectS
            let rush = route.first { $0.factorId == "T1" && $0.quantity == .time }?.timeEffectS
            if let head { headText = String(format: "%.0f s", head) }
            effectsOk = head.map { abs($0 - 90) <= 9 } == true && rush.map { abs($0 - 120) <= 12 } == true
            if let ex = FactorEffects.forRide(temp, rideId: ids[0], nowMs: now) {
                explainOk = Set(ex.items.map(\.factorId)) == ["W1", "T1"] && !ex.weatherMissing && ex.otherTimeS != nil
            }
        } catch {
            results.set("u31", .fail, "Seeding the temporary database failed: \(error.localizedDescription)")
            return
        }

        // 2. day types with the 2026 calendar: Yom Kippur = Saturday, its eve = Friday, a holiday week
        let days = OfflineHolidays.holidays(year: 2026)
        let yk = DayContextCalc.context(startAtMs: 1_789_966_800_000, utcOffsetMin: 180, holidays: days)
        let eve = DayContextCalc.context(startAtMs: 1_789_880_400_000, utcOffsetMin: 180, holidays: days)
        let dayOk = yk.dayType == "saturday" && !yk.rushHour && yk.holidayWeek && eve.dayType == "friday"

        // 3. gates: 2 windy rides = progress only; battery needs 5; rain pooled per km only; pure noise shows nothing
        let base = FactorSamples.commute()
        let two = FactorEngine.compute(rides: base.filter { $0.headwindKmh == 0 } + base.filter { $0.headwindKmh == 12 }.prefix(2),
                                       nowMs: FactorSamples.now(after: 24))
        let twoHead = two.first { $0.factorId == "W1" && $0.level == "head" && $0.scope == .route && $0.quantity == .time }
        let gateOk = twoHead?.gate == .notEnoughRides && twoHead?.n == 2 && twoHead?.effect == nil
            && two.filter { $0.factorId == "W3" }.allSatisfy { $0.scope == .pooled }
        let noise = FactorEngine.compute(rides: FactorSamples.commute(n: 120, noiseS: 30, noisePct: 0.5, effects: false),
                                         nowMs: FactorSamples.now(after: 120))
        let noiseOk = !noise.contains { $0.passesGate }

        // 4. weather missing: the ride waits (pattern W), nothing crashes
        let w = RideWeatherCalc.ride(startMs: now, endMs: now + 600_000, fixes: [], rows: [])
        let missingOk = w.isMissing && w.headwindKmh == nil

        let ok = columnsOk && effectsOk && explainOk && dayOk && gateOk && noiseOk && missingOk
        var phone = "no data"
        if let real, let c = try? FactorQueries(real).effectCount() {
            let rides = (try? FactorQueries(real).inputs().filter { !$0.isSimulated }) ?? []
            let withWeather = rides.filter { $0.windLevel != nil || $0.wet != nil }.count
            phone = "\(rides.count) rides, \(withWeather) with weather, \(c.passed) of \(c.rows) effects shown"
        }
        results.set("u31", ok ? .pass : .fail,
                    "ride columns (headwind, wet, day, rush hour) \(word(columnsOk)) · headwind effect \(headText) of 90, rush hour of 120 \(word(effectsOk)) · "
                    + "after-ride explanation \(word(explainOk)) · Yom Kippur = Saturday, eve = Friday, holiday week \(word(dayOk)) · "
                    + "gates (2 of 3 rides, rain pooled) \(word(gateOk)) · pure noise shows nothing \(word(noiseOk)) · weather missing waits \(word(missingOk)) · "
                    + "this phone: \(phone)")
    }
}
