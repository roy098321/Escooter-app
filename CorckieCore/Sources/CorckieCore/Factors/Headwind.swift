import Foundation

// M4-02: a ride's weather from the hourly `weather_hour` rows of its start cell (M4-01, decision 2): headwind (M16),
// wind level (T70), wet (M17, T71) and air temperature. Pure, no CoreLocation: the course comes from the GPS positions
// themselves (the bearing of each 10 s stretch), because `ride_sample.courseDeg` is not stored.

/// One GPS fix of a ride, as the factors read it. `t` = ms from the ride start.
public struct FactorFix: Equatable, Sendable {
    public var t: Int64
    public var lat: Double
    public var lon: Double
    public var hAccM: Double?

    public init(t: Int64, lat: Double, lon: Double, hAccM: Double? = nil) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.hAccM = hAccM
    }
}

/// The ride's weather columns (`headwindKmh`, `windLevel`, `wet`, `airTempC`). All nil = pattern W (weather not there yet).
public struct RideWeather: Equatable, Sendable {
    /// Distance-weighted mean of the wind component against the direction of travel, km/h; positive = headwind, negative =
    /// tailwind. Nil without GPS course (the ride is left out of the wind effects, not guessed).
    public var headwindKmh: Double?
    /// Mean wind speed during the ride, km/h
    public var windKmh: Double?
    /// light / moderate / strong (T70, from the wind speed)
    public var windLevel: String?
    /// dry / light / heavy (M17)
    public var wet: String?
    public var airTempC: Double?

    public init(headwindKmh: Double? = nil, windKmh: Double? = nil, windLevel: String? = nil, wet: String? = nil, airTempC: Double? = nil) {
        self.headwindKmh = headwindKmh
        self.windKmh = windKmh
        self.windLevel = windLevel
        self.wet = wet
        self.airTempC = airTempC
    }

    public static let missing = RideWeather()
    public var isMissing: Bool { windKmh == nil && wet == nil }
}

/// The interpolated weather at one moment (S2: linear for speed and temperature, shortest arc for the direction).
public struct WeatherAt: Equatable, Sendable {
    public var windKmh: Double
    public var windFromDeg: Double?
    public var airTempC: Double?
}

public enum FactorRules {
    /// A 10 s stretch (M16)
    public static let stretchMs: Int64 = 10_000
    /// Two fixes further apart than this are a GPS gap, not a stretch
    public static let maxFixGapMs: Int64 = 30_000
    /// A stretch must cover this much ground to have a direction
    public static let minStretchM = 10.0
    /// Under this much ground with a direction the ride gets no headwind
    public static let minCourseM = 300.0
    /// Hourly rows further apart than this are not interpolated
    public static let maxRowGapMs: Int64 = 2 * OutsideTime.hourMs
    /// A moment this close after the last row (or before the first) uses that row
    public static let edgeMs: Int64 = OutsideTime.hourMs
    /// W1 with / without: headwind >= 5 km/h is "head", <= -5 "tail", in between "calm" (the baseline). Guess, tune in P6
    public static let headwindLevelKmh = 5.0
    /// R1: elevation gain >= 10 m per km is a "hilly" ride. Guess
    public static let hillyGainPerKm = 10.0
    /// M24: rides older than this are not used (12 months, T67 rare factors)
    public static let windowMs: Int64 = 365 * OutsideTime.dayMs
    /// M24 confirmation regression: ridge penalty on standardised factors. Guess
    public static let ridgeLambda = 1.0
    /// The weather factors join the regression when at least this many rides have weather
    public static let regressionMinWeatherRides = 8
    /// M23 plausibility: scooter mass and the rolling-resistance share of the energy (75 kg rider default: T75 / M23)
    public static let scooterKg = 20.0
    public static let riderDefaultKg = 75.0
    public static let rollingShare = 0.4
    public static let plausibleFactor = 3.0
    /// M24 combined factors: together in more than 80% of their rides, until 3 rides apart
    public static let combinedShare = 0.8
    public static let combinedApart = 3
}

public enum RideWeatherCalc {
    /// Interpolates the rows (any order) at `atMs`. Nil when no row is close enough.
    public static func at(_ rows: [WeatherRow], atMs: Int64) -> WeatherAt? {
        let s = rows.sorted { $0.hourAt < $1.hourAt }
        guard let first = s.first, let last = s.last else { return nil }
        if atMs <= first.hourAt {
            return first.hourAt - atMs <= FactorRules.edgeMs ? point(first) : nil
        }
        if atMs >= last.hourAt {
            return atMs - last.hourAt <= FactorRules.edgeMs ? point(last) : nil
        }
        guard let i = s.lastIndex(where: { $0.hourAt <= atMs }), i + 1 < s.count else { return point(last) }
        let a = s[i], b = s[i + 1]
        let span = b.hourAt - a.hourAt
        if span > FactorRules.maxRowGapMs {
            // a hole in the hours: the nearer row if it is within the edge
            let da = atMs - a.hourAt, db = b.hourAt - atMs
            if da <= db { return da <= FactorRules.edgeMs ? point(a) : nil }
            return db <= FactorRules.edgeMs ? point(b) : nil
        }
        let f = span > 0 ? Double(atMs - a.hourAt) / Double(span) : 0
        let wind = a.windKmh + (b.windKmh - a.windKmh) * f
        var dir: Double?
        if let da = a.windFromDeg, let db = b.windFromDeg {
            var d = (db - da).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            dir = normalized(da + d * f)
        } else {
            dir = a.windFromDeg ?? b.windFromDeg
        }
        var temp: Double?
        if let ta = a.airTempC, let tb = b.airTempC { temp = ta + (tb - ta) * f } else { temp = a.airTempC ?? b.airTempC }
        return WeatherAt(windKmh: wind, windFromDeg: dir, airTempC: temp)
    }

    private static func point(_ r: WeatherRow) -> WeatherAt {
        WeatherAt(windKmh: r.windKmh, windFromDeg: r.windFromDeg.map(normalized), airTempC: r.airTempC)
    }

    static func normalized(_ deg: Double) -> Double {
        let d = deg.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Bearing (degrees from north, clockwise) of a displacement east / north in metres.
    static func bearing(east: Double, north: Double) -> Double {
        normalized(atan2(east, north) * 180 / Double.pi)
    }

    /// T70: light < 15, moderate 15-30, strong > 30 km/h of wind speed
    public static func windLevel(_ kmh: Double) -> String {
        if kmh < T.t70WindLightKmh { return "light" }
        return kmh > T.t70WindStrongKmh ? "strong" : "moderate"
    }

    /// M16: per 10 s stretch `wind x cos(windFrom - course)`, distance-weighted. Nil without enough GPS course or weather.
    public static func headwind(fixes: [FactorFix], rideStartMs: Int64, rows: [WeatherRow]) -> Double? {
        let good = fixes.filter { ($0.hAccM ?? 0) <= T.t28GoodFixM }.sorted { $0.t < $1.t }
        guard good.count >= 2 else { return nil }
        struct Stretch { var dist = 0.0; var east = 0.0; var north = 0.0; var tSum = 0.0 }
        var stretches: [Int64: Stretch] = [:]
        for i in 1..<good.count {
            let a = good[i - 1], b = good[i]
            guard b.t - a.t <= FactorRules.maxFixGapMs, b.t > a.t else { continue }
            let d = Geo.distanceM(GeoPoint(lat: a.lat, lon: a.lon), GeoPoint(lat: b.lat, lon: b.lon))
            guard d > 0.5 else { continue }
            let north = (b.lat - a.lat) * Geo.mPerDegLat
            let east = (b.lon - a.lon) * Geo.mPerDegLat * cos((a.lat + b.lat) / 2 * Double.pi / 180)
            let key = a.t / FactorRules.stretchMs
            var s = stretches[key] ?? Stretch()
            s.dist += d
            s.east += east
            s.north += north
            s.tSum += Double(a.t + b.t) / 2 * d
            stretches[key] = s
        }
        var weighted = 0.0, total = 0.0
        for (_, s) in stretches where s.dist >= FactorRules.minStretchM {
            let tMid = Int64(s.tSum / s.dist)
            guard let w = at(rows, atMs: rideStartMs + tMid), let from = w.windFromDeg else { continue }
            let course = bearing(east: s.east, north: s.north)
            let hw = w.windKmh * cos((from - course) * Double.pi / 180)
            weighted += hw * s.dist
            total += s.dist
        }
        guard total >= FactorRules.minCourseM else { return nil }
        return weighted / total
    }

    /// M17 / T71: wet when an hour during the ride has >= 0.2 mm, or rain fell in the window before it (1 h, + 1 h per 2 mm
    /// fallen, at most 4 h); heavy when a counted hour has >= 2.5 mm. A row at `hourAt` H holds the rain of the hour before H
    /// (Open-Meteo). Nil when an hour of the ride itself is missing (pattern W).
    public static func wet(startMs: Int64, endMs: Int64, rows: [WeatherRow]) -> String? {
        let byHour = Dictionary(rows.map { ($0.hourAt, $0) }, uniquingKeysWith: { a, _ in a })
        let hour = OutsideTime.hourMs
        // the rows whose hour overlaps the ride: H in (start, end + 1 h]
        var during: [Double] = []
        var h = OutsideTime.floorHour(startMs) + hour
        while h <= OutsideTime.floorHour(endMs) + hour {
            guard let r = byHour[h] else { return nil }
            during.append(r.precipMm ?? 0)
            h += hour
        }
        if during.isEmpty { return nil }
        let wetMm = T.t71WetMmPerH
        var counted = during.filter { $0 >= wetMm }
        // the window before the start: rows H <= start, H >= start - 4 h
        let windowStart: Int64 = startMs - Int64(T.t71WetMaxWindowH * Double(hour))
        let before: [WeatherRow] = rows.filter { r in r.hourAt <= startMs && r.hourAt >= windowStart && (r.precipMm ?? 0) >= wetMm }
        if let lastWet = before.map({ $0.hourAt }).max() {
            let fallen = before.reduce(0.0) { $0 + ($1.precipMm ?? 0) }
            let windowH = min(T.t71WetMaxWindowH, 1 + fallen / 2)
            if Double(startMs - lastWet) <= windowH * Double(hour) { counted += before.map { $0.precipMm ?? 0 } }
        }
        if counted.isEmpty { return "dry" }
        return counted.contains { $0 >= T.t71HeavyMmPerH } ? "heavy" : "light"
    }

    /// `wetOverride` ("wet" / "dry", offered Nov-Mar) wins over the weather.
    public static func applyOverride(_ wet: String?, override: String?) -> String? {
        switch override {
        case "dry": return "dry"
        case "wet": return wet == "heavy" ? "heavy" : "light"
        default: return wet
        }
    }

    /// Everything for one ride. `rows` = the start cell's hours from 4 h before the start to the end hour (history first,
    /// forecast where history has no row). The wind needs a row near the start, middle and end of the ride.
    public static func ride(startMs: Int64, endMs: Int64, fixes: [FactorFix], rows: [WeatherRow], wetOverride: String? = nil) -> RideWeather {
        let moments = [startMs, (startMs + endMs) / 2, endMs].compactMap { at(rows, atMs: $0) }
        guard moments.count == 3 else {
            let wet = applyOverride(wet(startMs: startMs, endMs: endMs, rows: rows), override: wetOverride)
            return RideWeather(wet: wet)
        }
        let wind = moments.map(\.windKmh).reduce(0, +) / 3
        let temps = moments.compactMap(\.airTempC)
        return RideWeather(headwindKmh: headwind(fixes: fixes, rideStartMs: startMs, rows: rows), windKmh: wind, windLevel: windLevel(wind),
                           wet: applyOverride(wet(startMs: startMs, endMs: endMs, rows: rows), override: wetOverride),
                           airTempC: temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count))
    }

    /// History rows first, a forecast row only for an hour history does not have.
    public static func merge(history: [WeatherRow], forecast: [WeatherRow]) -> [WeatherRow] {
        var byHour = Dictionary(forecast.map { ($0.hourAt, $0) }, uniquingKeysWith: { a, _ in a })
        for r in history { byHour[r.hourAt] = r }
        return byHour.values.sorted { $0.hourAt < $1.hourAt }
    }
}
