import CorckieCore
import Foundation

// M4-02: the factors engine on the stored rides. After every ride close (after calibration and routes, before the
// summary) and again when weather arrives (end of `OutsideDataService.runNow`), like `CalibrationUpdater`:
// 1. the ride's columns: day type / rush hour / holiday week always; headwind / wind level / wet / air temperature when the
//    weather of its start cell is there (else nil = pattern W, filled at the next run);
// 2. every `factor_effect` row rebuilt from the rides (real rides: per route + pooled; simulated rides: per route only, so
//    they never mix). Compiled into AppTests with App/Store.

enum FactorUpdater {
    struct Report: Equatable {
        /// rides whose columns were (re)written
        var ridesFilled = 0
        /// of those, rides that got weather
        var withWeather = 0
        var effects = 0
        var passed = 0

        var text: String { "Factors: \(ridesFilled) rides (\(withWeather) with weather), \(passed) of \(effects) effects shown" }
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// The ride's columns (when `rideId` is given), the rides still missing theirs, then all effects.
    @discardableResult
    static func update(_ database: AppDatabase, rideId: String?, nowMs: Int64 = nowMs()) throws -> Report {
        guard !database.isReadOnly else { return Report() }
        var report = Report()
        var ids = (try? FactorQueries(database).pending(limit: 40)) ?? []
        if let rideId, !ids.contains(rideId) { ids.insert(rideId, at: 0) }
        for id in ids {
            if let got = try fill(database, rideId: id) {
                report.ridesFilled += 1
                if got { report.withWeather += 1 }
            }
        }
        let effects = try rebuild(database, nowMs: nowMs)
        report.effects = effects.count
        report.passed = effects.filter(\.passesGate).count
        return report
    }

    /// Weather arrived (or app open): fill what is missing and rebuild.
    @discardableResult
    static func refreshPending(_ database: AppDatabase, nowMs: Int64 = nowMs()) throws -> Report {
        try update(database, rideId: nil, nowMs: nowMs)
    }

    /// The weather rows of a ride's start cell: from 4 h before the start (rain window) to the hour after the end;
    /// history first, forecast for the hours history does not have.
    static func weatherRows(_ store: OutsideQueries, cell: String, startMs: Int64, endMs: Int64) -> [WeatherRow] {
        let from = OutsideTime.floorHour(startMs) - OutsideRules.rainWindowMs
        let to = OutsideTime.floorHour(endMs) + OutsideTime.hourMs
        let history = (try? store.weather(cell: cell, from: from, to: to, kind: .history)) ?? []
        let forecast = (try? store.weather(cell: cell, from: from, to: to, kind: .forecast)) ?? []
        return RideWeatherCalc.merge(history: history, forecast: forecast)
    }

    /// Holidays for the years a ride needs: the stored list, else the offline calendar (works before the first refresh).
    static func holidays(_ store: OutsideQueries, startMs: Int64, utcOffsetMin: Int) -> [Holiday] {
        var out: [Holiday] = []
        for year in DayContextCalc.years(startAtMs: startMs, utcOffsetMin: utcOffsetMin) {
            let stored = ((try? store.holidays(year: year)) ?? []).map(\.holiday)
            out += stored.isEmpty ? OfflineHolidays.holidays(year: year) : stored
        }
        return out
    }

    /// Writes one ride's columns. nil = no such ride (or still recording); true = it has weather now.
    static func fill(_ database: AppDatabase, rideId: String) throws -> Bool? {
        let q = FactorQueries(database)
        guard let r = try q.input(rideId: rideId), let end = r.endAt else { return nil }
        let outside = OutsideQueries(database)
        let offset = r.utcOffsetMin ?? 0
        let day = DayContextCalc.context(startAtMs: r.startAt, utcOffsetMin: offset, holidays: holidays(outside, startMs: r.startAt, utcOffsetMin: offset))
        let fixes = try q.fixes(rideId: rideId)
        var weather = RideWeather.missing
        if let first = fixes.first {
            let rows = weatherRows(outside, cell: GeoCell.key(lat: first.lat, lon: first.lon), startMs: r.startAt, endMs: end)
            weather = RideWeatherCalc.ride(startMs: r.startAt, endMs: end, fixes: fixes, rows: rows, wetOverride: r.wetOverride)
        }
        try q.setColumns(rideId: rideId, weather: weather, day: day)
        return !weather.isMissing
    }

    static func ride(from r: FactorInputRow) -> FactorRide {
        FactorRide(id: r.id, routeId: r.routeId, startAt: r.startAt, distanceM: r.distanceM ?? 0, totalS: r.totalS, usedPct: r.usedPct,
                   gapScooterS: r.gapScooterS ?? 0, headwindKmh: r.headwindKmh, wet: r.wet, rushHour: r.rushHour ?? false, dayType: r.dayType,
                   loadKg: r.loadKg, likelyLoaded: r.promptAnswer == FactorUpdater.likelyLoadedAnswer, elevGainM: r.elevGainM,
                   excluded: r.excludedFromUsual, kind: r.kind)
    }

    /// The smart prompt's (M4-05) answer that marks a ride as likely loaded without a tag
    static let likelyLoadedAnswer = "likelyLoaded"

    /// All effects from the stored rides, saved in `factor_effect`.
    static func rebuild(_ database: AppDatabase, nowMs: Int64) throws -> [FactorEffect] {
        let rows = try FactorQueries(database).inputs()
        let real = rows.filter { !$0.isSimulated }.map(ride(from:))
        let simulated = rows.filter(\.isSimulated).map(ride(from:))
        var effects = FactorEngine.compute(rides: real, nowMs: nowMs, pooled: true)
        if !simulated.isEmpty { effects += FactorEngine.compute(rides: simulated, nowMs: nowMs, pooled: false) }
        try FactorQueries(database).replaceEffects(effects, computedAt: nowMs)
        return effects
    }
}

/// Hand-off to M4-03 insights and M4-08 Factors page (reads `factor_effect`; never shows an effect under its gate).
enum FactorEffects {
    /// After-ride explanation: the ride's factors (scaled to the real difference from its route's usual), the rest "other".
    static func forRide(_ database: AppDatabase, rideId: String, nowMs: Int64 = FactorUpdater.nowMs()) -> RideExplanation? {
        let q = FactorQueries(database)
        guard let r = try? q.input(rideId: rideId) else { return nil }
        let ride = FactorUpdater.ride(from: r)
        var routeRides: [FactorRide] = []
        if let routeId = r.routeId {
            routeRides = ((try? q.inputs()) ?? []).filter { $0.routeId == routeId && $0.isSimulated == r.isSimulated }.map(FactorUpdater.ride(from:))
        }
        let effects = (try? q.effects()) ?? []
        let mine = effects.filter { $0.scope == .pooled ? !r.isSimulated : $0.routeId == r.routeId }
        return FactorEngine.explain(ride: ride, routeRides: routeRides, effects: mine, nowMs: nowMs)
    }

    /// Per trip on one route (W1 head / tail, T1 rush, T2 friday / saturday; time and battery), with counts and the gate.
    static func forRoute(_ database: AppDatabase, routeId: String) -> [FactorEffect] {
        (try? FactorQueries(database).effects(scope: .route, routeId: routeId)) ?? []
    }

    /// Per km over all routes (real rides, last 12 months; load per km per kg).
    static func forPooled(_ database: AppDatabase) -> [FactorEffect] {
        (try? FactorQueries(database).effects(scope: .pooled)) ?? []
    }

    /// The developer line on the ride detail (check mf1): the ride's factor columns.
    static func developerLine(_ database: AppDatabase, rideId: String) -> String? {
        guard let r = try? FactorQueries(database).input(rideId: rideId) else { return nil }
        var parts: [String] = []
        if r.windLevel == nil && r.wet == nil {
            parts.append(r.hasGps == true ? "weather not there yet" : "no weather (no GPS)")
        } else {
            if let h = r.headwindKmh {
                parts.append(String(format: "%@ %.0f km/h", h >= 0 ? "headwind" : "tailwind", abs(h)))
            } else {
                parts.append("headwind unknown")
            }
            if let w = r.windLevel { parts.append("wind \(w)") }
            if let wet = r.wet { parts.append(wet == "dry" ? "dry" : "wet (\(wet))") }
            if let t = r.airTempC { parts.append(String(format: "%.0f °C", t)) }
        }
        if let d = r.dayType { parts.append(d) }
        if r.rushHour == true { parts.append("rush hour") }
        if r.holidayWeek == true { parts.append("holiday week") }
        if let kg = r.loadKg, kg > 0 { parts.append(String(format: "load %.0f kg", kg)) }
        return "Factors: " + parts.joined(separator: " · ")
    }
}

/// A made-up windy commute in the ocean (no real place): 24 workday rides on one route, a straight 5 km line north with GPS
/// every 5 s and weather rows that give a headwind of 12 / 0 / -12 km/h; time and battery follow `FactorSamples.commute`.
/// Used by the in-app check u31 and the app-tests, always in a temporary database.
enum FactorSeed {
    static let lat0 = 10.0, lon0 = -30.0
    static let utcOffsetMin = 180

    @discardableResult
    static func commute(_ database: AppDatabase, routeId: String = "seed-route", n: Int = 24, withWeather: Bool = true) throws -> [String] {
        let base = FactorSamples.commute(routeId: routeId, n: n)
        let rides = RideQueries(database)
        let outside = OutsideQueries(database)
        var day = FactorSamples.t0
        var ids: [String] = []
        let mPerDeg = Double.pi * Geo.earthRadiusM / 180
        for r in base {
            // workdays only (Sun-Thu): Friday and Saturday would be other day types
            while DayClock.weekday(startAtMs: day, utcOffsetMin: utcOffsetMin) >= 5 { day += FactorSamples.day }
            let start = day + (r.rushHour ? 5 : 9) * OutsideTime.hourMs     // 08:00 or 12:00 local
            day += FactorSamples.day
            let totalS = r.totalS ?? 900
            var rec = RideRecord(id: r.id, startAt: start)
            rec.status = "ended"
            rec.kind = "ride"
            rec.endAt = start + Int64(totalS * 1000)
            rec.utcOffsetMin = utcOffsetMin
            rec.distanceM = r.distanceM
            rec.totalS = totalS
            rec.movingS = totalS
            rec.usedPct = r.usedPct
            rec.hasGps = true
            try rides.save(rec)
            try database.writer.write { db in
                try db.execute(sql: "UPDATE ride SET routeId = ? WHERE id = ?", arguments: [routeId, r.id])
            }
            let steps = Int(totalS / 5)
            var samples: [RideSampleRecord] = []
            for s in 0...steps {
                var x = RideSampleRecord(rideId: r.id, t: Int64(s) * 5_000)
                x.lat = lat0 + r.distanceM * Double(s) / Double(steps) / mPerDeg
                x.lon = lon0
                x.hAccM = 5
                samples.append(x)
            }
            try rides.insert(samples: samples)
            ids.append(r.id)
            guard withWeather else { continue }
            let hw = r.headwindKmh ?? 0
            let cell = GeoCell.key(lat: lat0, lon: lon0)
            var rows: [WeatherRow] = []
            var h = OutsideTime.floorHour(start) - OutsideRules.rainWindowMs
            while h <= OutsideTime.floorHour(start + Int64(totalS * 1000)) + OutsideTime.hourMs {
                rows.append(WeatherRow(cellKey: cell, hourAt: h, source: "seed", kind: .history, windKmh: abs(hw), windFromDeg: hw >= 0 ? 0 : 180,
                                       precipMm: 0, airTempC: 27, fetchedAt: start))
                h += OutsideTime.hourMs
            }
            try outside.save(weather: rows)
        }
        return ids
    }
}
