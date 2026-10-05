import Foundation

// M4-01 Outside data for real (ARCHITECTURE section 3 and 4, DATA_MODEL outside-data tables).
// Pure logic: the hourly weather cache, the history backfill for past rides, holidays and map elevation, with the
// decided fallbacks. The network is a closure (the app passes URLSession, the tests pass a stub) and the cache is a
// protocol (the app passes the SQLite tables, the tests pass memory), so it all runs on Linux.
//
// Policy P-2: only a coarse location ever leaves the phone: every coordinate is rounded to a 0.01 degree cell
// (~1.1 km) before a request is built (`GeoCell`). Nothing in this file builds a URL from a finer position.

// MARK: Time and cells

public enum OutsideTime {
    public static let hourMs: Int64 = 3_600_000
    public static let dayMs: Int64 = 86_400_000

    public static func floorHour(_ ms: Int64) -> Int64 { ms - (((ms % hourMs) + hourMs) % hourMs) }

    public static func floorDay(_ ms: Int64) -> Int64 { ms - (((ms % dayMs) + dayMs) % dayMs) }

    /// "yyyy-MM-dd" in UTC (the weather APIs are asked in UTC).
    public static func day(_ ms: Int64) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// A 0.01 degree grid cell (~1.1 km). The key is the two whole cell numbers ("1001,-3003" = 10.01, -30.03).
public enum GeoCell {
    public static let step = 0.01

    public static func key(lat: Double, lon: Double) -> String {
        "\(Int((lat / step).rounded())),\(Int((lon / step).rounded()))"
    }

    /// The cell's rounded coordinates: the only position a request may carry.
    public static func center(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        (Double(Int((lat / step).rounded())) * step, Double(Int((lon / step).rounded())) * step)
    }

    public static func center(key: String) -> (lat: Double, lon: Double)? {
        let parts = key.split(separator: ",")
        guard parts.count == 2, let la = Int(parts[0]), let lo = Int(parts[1]) else { return nil }
        return (Double(la) * step, Double(lo) * step)
    }
}

// MARK: Rows

public enum WeatherKind: String, Sendable { case forecast, history }

/// One `weather_hour` row. `hourAt` = epoch ms at the start of the hour (UTC).
public struct WeatherRow: Equatable, Sendable {
    public var cellKey: String
    public var hourAt: Int64
    /// open-meteo / met-no / open-meteo-archive
    public var source: String
    public var kind: WeatherKind
    public var windKmh: Double
    public var windFromDeg: Double?
    public var gustKmh: Double?
    public var precipMm: Double?
    public var airTempC: Double?
    public var fetchedAt: Int64

    public init(cellKey: String, hourAt: Int64, source: String, kind: WeatherKind, windKmh: Double, windFromDeg: Double? = nil,
                gustKmh: Double? = nil, precipMm: Double? = nil, airTempC: Double? = nil, fetchedAt: Int64) {
        self.cellKey = cellKey
        self.hourAt = hourAt
        self.source = source
        self.kind = kind
        self.windKmh = windKmh
        self.windFromDeg = windFromDeg
        self.gustKmh = gustKmh
        self.precipMm = precipMm
        self.airTempC = airTempC
        self.fetchedAt = fetchedAt
    }

    init(cell: String, hour: WeatherHour, source: String, kind: WeatherKind, fetchedAt: Int64) {
        self.init(cellKey: cell, hourAt: OutsideTime.floorHour(Int64(hour.time.timeIntervalSince1970 * 1000)), source: source, kind: kind,
                  windKmh: hour.windKmh, windFromDeg: hour.windFromDeg, gustKmh: hour.gustKmh, precipMm: hour.precipMm,
                  airTempC: hour.airTempC, fetchedAt: fetchedAt)
    }
}

public struct StoredHoliday: Equatable, Sendable {
    public var holiday: Holiday
    /// hebcal / offline
    public var source: String

    public init(holiday: Holiday, source: String) {
        self.holiday = holiday
        self.source = source
    }
}

/// The cache. The app implements it with the SQLite tables (`weather_hour`, `elevation_point`, `holiday`, `setting`).
public protocol OutsideStore {
    /// Rows of one kind for the cell with `from <= hourAt <= to`, oldest first.
    func weather(cell: String, from: Int64, to: Int64, kind: WeatherKind) throws -> [WeatherRow]
    /// Insert or replace by (cell, hour, kind).
    func save(weather: [WeatherRow]) throws
    /// Delete rows with an hour older than `before` (epoch ms): the 13-month rule.
    func pruneWeather(before: Int64) throws
    func elevation(cell: String) throws -> Double?
    func save(elevations: [String: Double], source: String) throws
    func holidays(year: Int) throws -> [StoredHoliday]
    /// Replaces every holiday of the year.
    func replaceHolidays(year: Int, with days: [Holiday], source: String) throws
    /// When a source was last asked for a key (epoch ms): one try a day for the history and the holidays.
    func lastAttempt(_ key: String) throws -> Int64?
    func markAttempt(_ key: String, at: Int64) throws
}

// MARK: Results (what the screens and the checks read)

public enum WeatherOutcome: Equatable, Sendable {
    /// Just fetched; `source` = open-meteo or met-no
    case fresh(hours: Int, source: String)
    /// Cache younger than 60 min: no request made
    case cached(hours: Int, ageMin: Int)
    /// Both sources failed: the cache, up to 24 h old, with its age
    case stale(hours: Int, ageMin: Int)
    /// Both sources failed and nothing usable cached: no weather-aware estimate (plain usual range)
    case none

    public var hasForecast: Bool { self != .none }

    /// ARCHITECTURE section 4 words.
    public var text: String {
        switch self {
        case let .fresh(hours, source): return "Forecast updated · \(hours) hours · \(source == "met-no" ? "MET Norway" : "Open-Meteo")"
        case let .cached(hours, ageMin): return "Forecast \(ageMin) min old · \(hours) hours"
        case let .stale(hours, ageMin): return "Forecast \(ageMin >= 120 ? "\(ageMin / 60) h" : "\(ageMin) min") old · \(hours) hours · no connection"
        case .none: return "No forecast"
        }
    }
}

public struct BackfillRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var endAt: Int64
    /// The ride's first GPS fix (rounded to a cell before use); nil = no GPS ride
    public var lat: Double?
    public var lon: Double?

    public init(id: String, startAt: Int64, endAt: Int64, lat: Double?, lon: Double?) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.lat = lat
        self.lon = lon
    }
}

public struct BackfillReport: Equatable, Sendable {
    /// rides whose weather was filled in this run
    public var filled = 0
    /// rides that already had every hour
    public var alreadyCached = 0
    /// no GPS fix, or too recent (the last hour is not over yet)
    public var skipped = 0
    /// asked and not answered (or throttled): tried again at the next run, at most once a day
    public var pending = 0
    /// requests sent
    public var requests = 0
    /// days that came from the Archive API (rides older than 30 days)
    public var archiveDays = 0

    public init() {}
}

public struct ElevationReport: Equatable, Sendable {
    public var cached = 0
    public var fetched = 0
    public var failed = 0

    public init() {}
}

public struct HolidayReport: Equatable, Sendable {
    /// year -> where the days came from (hebcal / cached / offline)
    public var years: [Int: String] = [:]

    public init() {}
}

// MARK: Rules

public enum OutsideRules {
    /// Forecast refreshed at most every 60 min (ARCHITECTURE section 3)
    public static let forecastRefreshMs: Int64 = 60 * 60_000
    /// Cached forecast usable up to 24 h old when both sources fail (section 4, rows 7 and 16)
    public static let forecastStaleMaxMs: Int64 = 24 * 3_600_000
    /// Hours of forecast kept (now to +48 h)
    public static let forecastHoursAhead = 48
    /// Rain window before a ride (M17: up to 4 h)
    public static let rainWindowMs: Int64 = 4 * OutsideTime.hourMs
    /// History: retried daily for 30 days, then the Archive API (section 4, row 7)
    public static let historyRetryDays: Int64 = 30
    /// A ride's last hour must be over before its history is asked for
    public static let historyMinAgeMs: Int64 = OutsideTime.hourMs
    /// Weather kept 13 months (DATA_MODEL)
    public static let keepWeatherMs: Int64 = 396 * OutsideTime.dayMs
    /// At most one try per key per day after a failure
    public static let retryEveryMs: Int64 = OutsideTime.dayMs
    /// Requests per backfill run (polite, and the run stays short)
    public static let maxHistoryRequests = 12
    /// Elevation API: up to 100 points per call
    public static let elevationPerCall = 100
    /// A Hebcal year has far more than this many days
    public static let minHebcalDays = 20
}

// MARK: Client

public struct OutsideClient {
    public typealias Fetch = (URL) async throws -> Data

    let store: OutsideStore
    let fetch: Fetch
    let now: () -> Int64

    /// `fetch` does the retries (10 s timeout, 2 retries) and throws offline; `now` = epoch ms.
    public init(store: OutsideStore, fetch: @escaping Fetch, now: @escaping () -> Int64) {
        self.store = store
        self.fetch = fetch
        self.now = now
    }

    // MARK: Forecast (e3, e4)

    /// Open-Meteo, then MET Norway, then the cache up to 24 h old, else nothing. Never throws. The cache answers
    /// without a request while it is younger than 60 min. Only the cell's rounded position is sent.
    public func refreshForecast(lat: Double, lon: Double) async -> WeatherOutcome {
        let cell = GeoCell.key(lat: lat, lon: lon)
        let at = GeoCell.center(lat: lat, lon: lon)
        let nowMs = now()
        let hourNow = OutsideTime.floorHour(nowMs)
        let horizon = hourNow + Int64(OutsideRules.forecastHoursAhead) * OutsideTime.hourMs
        let cached = (try? store.weather(cell: cell, from: hourNow, to: horizon, kind: .forecast)) ?? []
        let newest = cached.map(\.fetchedAt).max()
        if let newest, nowMs - newest < OutsideRules.forecastRefreshMs, cached.count >= 6 {
            return .cached(hours: cached.count, ageMin: Int((nowMs - newest) / 60_000))
        }
        var hours: [WeatherHour]?
        var source = ""
        do {
            hours = try OutsideParsers.openMeteoHourly(try await fetch(OutsideParsers.openMeteoForecastURL(lat: at.lat, lon: at.lon)))
            source = "open-meteo"
        } catch {
            do {
                hours = try OutsideParsers.metNorwayHourly(try await fetch(OutsideParsers.metNorwayURL(lat: at.lat, lon: at.lon)))
                source = "met-no"
            } catch {
                hours = nil
            }
        }
        if let hours {
            let rows = hours.map { WeatherRow(cell: cell, hour: $0, source: source, kind: .forecast, fetchedAt: nowMs) }
                .filter { $0.hourAt <= horizon }
            if !rows.isEmpty, (try? store.save(weather: rows)) != nil {
                try? store.pruneWeather(before: nowMs - OutsideRules.keepWeatherMs)
                return .fresh(hours: rows.filter { $0.hourAt >= hourNow }.count, source: source)
            }
        }
        if let newest, nowMs - newest <= OutsideRules.forecastStaleMaxMs, !cached.isEmpty {
            return .stale(hours: cached.count, ageMin: Int((nowMs - newest) / 60_000))
        }
        return .none
    }

    // MARK: History for past rides (e5)

    /// Fills `weather_hour` (kind history) for the hours of each ride and the 4 h before it. One request per cell and
    /// UTC day; the Historical Forecast API first. A failed day is asked again after 24 h; for rides older than 30
    /// days the Archive API is tried too. Rides with no GPS fix or still inside their last hour are skipped. Never throws.
    public func backfillHistory(rides: [BackfillRide], maxRequests: Int = OutsideRules.maxHistoryRequests) async -> BackfillReport {
        var report = BackfillReport()
        let nowMs = now()
        for ride in rides.sorted(by: { $0.startAt > $1.startAt }) {
            guard let lat = ride.lat, let lon = ride.lon, ride.endAt >= ride.startAt else { report.skipped += 1; continue }
            if nowMs - ride.endAt < OutsideRules.historyMinAgeMs { report.skipped += 1; continue }
            let cell = GeoCell.key(lat: lat, lon: lon)
            let from = OutsideTime.floorHour(ride.startAt - OutsideRules.rainWindowMs)
            let to = OutsideTime.floorHour(ride.endAt)
            if covered(cell, from, to) { report.alreadyCached += 1; continue }
            var complete = true
            var day = OutsideTime.floorDay(from)
            while day <= to {
                let dayFrom = max(from, day), dayTo = min(to, day + OutsideTime.dayMs - OutsideTime.hourMs)
                if !covered(cell, dayFrom, dayTo) {
                    let key = "history|\(cell)|\(OutsideTime.day(day))"
                    if let last = try? store.lastAttempt(key), nowMs - last < OutsideRules.retryEveryMs {
                        complete = false
                    } else if report.requests >= maxRequests {
                        complete = false
                    } else {
                        let old = nowMs - ride.endAt > OutsideRules.historyRetryDays * OutsideTime.dayMs
                        let got = await fetchDay(cell: cell, day: day, archive: old, report: &report)
                        try? store.markAttempt(key, at: nowMs)
                        if !got || !covered(cell, dayFrom, dayTo) { complete = false }
                    }
                }
                day += OutsideTime.dayMs
            }
            if complete { report.filled += 1 } else { report.pending += 1 }
        }
        return report
    }

    private func covered(_ cell: String, _ from: Int64, _ to: Int64) -> Bool {
        let needed = Int((to - from) / OutsideTime.hourMs) + 1
        let have = (try? store.weather(cell: cell, from: from, to: to, kind: .history)) ?? []
        return have.count >= needed
    }

    /// One cell and one UTC day. The Historical Forecast API first; for rides older than 30 days the Archive API after it.
    private func fetchDay(cell: String, day: Int64, archive: Bool, report: inout BackfillReport) async -> Bool {
        guard let at = GeoCell.center(key: cell) else { return false }
        let text = OutsideTime.day(day)
        let nowMs = now()
        report.requests += 1
        do {
            let hours = try OutsideParsers.openMeteoHourly(try await fetch(OutsideParsers.openMeteoHistoryURL(lat: at.lat, lon: at.lon, day: text)))
            try store.save(weather: hours.map { WeatherRow(cell: cell, hour: $0, source: "open-meteo", kind: .history, fetchedAt: nowMs) })
            return true
        } catch {
            if !archive { return false }
        }
        report.requests += 1
        do {
            let hours = try OutsideParsers.openMeteoHourly(try await fetch(OutsideParsers.openMeteoArchiveURL(lat: at.lat, lon: at.lon, day: text)))
            try store.save(weather: hours.map { WeatherRow(cell: cell, hour: $0, source: "open-meteo-archive", kind: .history, fetchedAt: nowMs) })
            report.archiveDays += 1
            return true
        } catch {
            return false
        }
    }

    // MARK: Elevation (e6)

    /// Map elevation for cells (~1 km). Cached forever; the rest asked in batches of up to 100. A failure leaves the
    /// cell without a value (the caller keeps the barometer-only "~" elevation). Never throws.
    public func elevations(cells: [String]) async -> ElevationReport {
        var report = ElevationReport()
        var seen = Set<String>()
        var missing: [String] = []
        for cell in cells where seen.insert(cell).inserted {
            if (try? store.elevation(cell: cell)) != nil {
                report.cached += 1
            } else if GeoCell.center(key: cell) != nil {
                missing.append(cell)
            }
        }
        var index = 0
        while index < missing.count {
            let batch = Array(missing[index..<min(index + OutsideRules.elevationPerCall, missing.count)])
            index += OutsideRules.elevationPerCall
            let points = batch.compactMap { GeoCell.center(key: $0) }
            do {
                let metres = try OutsideParsers.elevations(try await fetch(OutsideParsers.elevationURL(points: points)))
                guard metres.count == batch.count else { throw OutsideParseError.missing("elevation") }
                try store.save(elevations: Dictionary(uniqueKeysWithValues: zip(batch, metres)), source: "open-meteo-dem")
                report.fetched += batch.count
            } catch {
                report.failed += batch.count
            }
        }
        return report
    }

    // MARK: Holidays (e2)

    /// Hebcal for each year; fails to the offline Hebrew-calendar days (kept as source "offline" and replaced by the
    /// real list at the next success). A year with Hebcal days cached is not asked again. Never throws.
    public func refreshHolidays(years: [Int]) async -> HolidayReport {
        var report = HolidayReport()
        let nowMs = now()
        for year in years {
            let stored = (try? store.holidays(year: year)) ?? []
            if stored.filter({ $0.source == "hebcal" }).count >= OutsideRules.minHebcalDays {
                report.years[year] = "cached"
                continue
            }
            let key = "holidays|\(year)"
            if !stored.isEmpty, let last = try? store.lastAttempt(key), nowMs - last < OutsideRules.retryEveryMs {
                report.years[year] = "offline"
                continue
            }
            do {
                let days = try OutsideParsers.holidays(try await fetch(OutsideParsers.hebcalURL(year: year)))
                try store.replaceHolidays(year: year, with: days, source: "hebcal")
                report.years[year] = "hebcal"
            } catch {
                try? store.markAttempt(key, at: nowMs)
                if stored.isEmpty {
                    try? store.replaceHolidays(year: year, with: OfflineHolidays.holidays(year: year), source: "offline")
                }
                report.years[year] = "offline"
            }
        }
        return report
    }
}
