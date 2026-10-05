import XCTest
@testable import CorckieCore

/// The cache in memory, same rules as the SQLite one (the app-tests run the real tables).
final class MemoryOutsideStore: OutsideStore {
    var rows: [String: WeatherRow] = [:]
    var elev: [String: Double] = [:]
    var days: [Int: [StoredHoliday]] = [:]
    var attempts: [String: Int64] = [:]

    func weather(cell: String, from: Int64, to: Int64, kind: WeatherKind) throws -> [WeatherRow] {
        rows.values.filter { $0.cellKey == cell && $0.kind == kind && $0.hourAt >= from && $0.hourAt <= to }.sorted { $0.hourAt < $1.hourAt }
    }

    func save(weather: [WeatherRow]) throws {
        for r in weather { rows["\(r.cellKey)|\(r.hourAt)|\(r.kind.rawValue)"] = r }
    }

    func pruneWeather(before: Int64) throws {
        rows = rows.filter { $0.value.hourAt >= before }
    }

    func elevation(cell: String) throws -> Double? { elev[cell] }

    func save(elevations: [String: Double], source: String) throws {
        for (k, v) in elevations { elev[k] = v }
    }

    func holidays(year: Int) throws -> [StoredHoliday] { days[year] ?? [] }

    func replaceHolidays(year: Int, with list: [Holiday], source: String) throws {
        days[year] = list.map { StoredHoliday(holiday: $0, source: source) }
    }

    func lastAttempt(_ key: String) throws -> Int64? { attempts[key] }

    func markAttempt(_ key: String, at: Int64) throws { attempts[key] = at }
}

typealias StubNet = FakeOutsideNet

final class OutsideDataTests: XCTestCase {
    private var store = MemoryOutsideStore()
    private var net = StubNet()
    // a made-up place in the ocean: no real coordinate is ever used
    private let lat = 10.01234, lon = -30.02912

    override func setUp() {
        store = MemoryOutsideStore()
        net = StubNet()
    }

    private func client() -> OutsideClient {
        OutsideClient(store: store, fetch: net.fetch, now: { [net] in net.clock })
    }

    private func ride(_ id: String, daysAgo: Double, minutes: Double = 30, gps: Bool = true) -> BackfillRide {
        // midday UTC, so the 4 h before and the ride stay on one UTC day
        let start = OutsideTime.floorDay(net.clock) - Int64(daysAgo * 86_400_000) + 12 * OutsideTime.hourMs
        return BackfillRide(id: id, startAt: start, endAt: start + Int64(minutes * 60_000), lat: gps ? lat : nil, lon: gps ? lon : nil)
    }

    // MARK: Cells and privacy (P-2)

    func test_cell_roundsToAbout1km() {
        XCTAssertEqual(GeoCell.key(lat: 10.0123, lon: -30.0291), "1001,-3003")
        XCTAssertEqual(GeoCell.key(lat: 10.0149, lon: -30.0251), "1001,-3003")
        XCTAssertNotEqual(GeoCell.key(lat: 10.0151, lon: -30.0291), "1001,-3003")
        let c = GeoCell.center(key: "1001,-3003")
        XCTAssertEqual(c?.lat ?? 0, 10.01, accuracy: 1e-9)
        XCTAssertEqual(c?.lon ?? 0, -30.03, accuracy: 1e-9)
        XCTAssertNil(GeoCell.center(key: "nonsense"))
    }

    func test_everyRequestCarriesOnlyTheRoundedCell() async {
        net.down = ["api.open-meteo.com"]   // so the MET Norway URL is built too
        let c = client()
        _ = await c.refreshForecast(lat: lat, lon: lon)
        net.down = []
        net.clock += 2 * OutsideTime.hourMs
        _ = await c.refreshForecast(lat: lat, lon: lon)
        _ = await c.backfillHistory(rides: [ride("a", daysAgo: 3)])
        _ = await c.backfillHistory(rides: [ride("b", daysAgo: 60)])
        _ = await c.elevations(cells: [GeoCell.key(lat: lat, lon: lon)])
        XCTAssertGreaterThan(net.urls.count, 5)
        let fine = try! NSRegularExpression(pattern: "(latitude|longitude|lat|lon)=[-0-9.,]*-?\\d+\\.\\d{3,}")
        for url in net.urls {
            let s = url.absoluteString
            XCTAssertNil(fine.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), "more than 2 decimals sent: \(s)")
        }
        XCTAssertTrue(net.urls.contains { $0.absoluteString.contains("latitude=10.01&longitude=-30.03") })
        XCTAssertTrue(net.urls.contains { $0.absoluteString.contains("lat=10.01&lon=-30.03") })
    }

    // MARK: Forecast cache and fallbacks

    func test_forecast_fresh_thenServedFromCacheFor60min() async {
        let c = client()
        let first = await c.refreshForecast(lat: lat, lon: lon)
        guard case let .fresh(hours, source) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(source, "open-meteo")
        XCTAssertGreaterThan(hours, 24)
        let rows = try! store.weather(cell: "1001,-3003", from: 0, to: Int64.max, kind: .forecast)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.hourAt % OutsideTime.hourMs == 0 && $0.source == "open-meteo" && $0.fetchedAt == net.clock })
        XCTAssertEqual(net.urls.count, 1)

        net.clock += 30 * 60_000
        let second = await c.refreshForecast(lat: lat, lon: lon)
        guard case let .cached(_, age) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(age, 30)
        XCTAssertEqual(net.urls.count, 1, "no request while the cache is younger than 60 min")

        net.clock += 31 * 60_000
        _ = await c.refreshForecast(lat: lat, lon: lon)
        XCTAssertEqual(net.urls.count, 2)
    }

    func test_forecast_openMeteoDown_usesMetNorway() async {
        net.down = ["api.open-meteo.com"]
        let out = await client().refreshForecast(lat: lat, lon: lon)
        guard case let .fresh(_, source) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(source, "met-no")
        let rows = try! store.weather(cell: "1001,-3003", from: 0, to: Int64.max, kind: .forecast)
        XCTAssertTrue(rows.allSatisfy { $0.source == "met-no" })
        XCTAssertEqual(rows.first?.windKmh ?? 0, 3 * 3.6, accuracy: 1e-6)
    }

    func test_forecast_bothDown_cacheUpTo24hThenNothing() async {
        let c = client()
        _ = await c.refreshForecast(lat: lat, lon: lon)
        net.offline = true
        net.clock += 3 * OutsideTime.hourMs
        let stale = await c.refreshForecast(lat: lat, lon: lon)
        guard case let .stale(_, age) = stale else { return XCTFail("\(stale)") }
        XCTAssertEqual(age, 180)
        XCTAssertTrue(stale.text.contains("3 h old"))
        XCTAssertTrue(stale.hasForecast)
        // 25 h after the fetch: the cached hours are older than 24 h
        net.clock += 22 * OutsideTime.hourMs
        let gone = await c.refreshForecast(lat: lat, lon: lon)
        XCTAssertEqual(gone, .none)
        XCTAssertEqual(gone.text, "No forecast")
        XCTAssertFalse(gone.hasForecast)
    }

    func test_forecast_neverCachedAndOffline_isNoForecast_noCrash() async {
        net.offline = true
        let out = await client().refreshForecast(lat: lat, lon: lon)
        XCTAssertEqual(out, .none)
        XCTAssertTrue(store.rows.isEmpty)
    }

    func test_forecast_garbageAnswer_isAFailure() async {
        let garbage = OutsideClient(store: store, fetch: { _ in Data("<html>oops</html>".utf8) }, now: { [net] in net.clock })
        let out = await garbage.refreshForecast(lat: lat, lon: lon)
        XCTAssertEqual(out, .none)
        XCTAssertTrue(store.rows.isEmpty)
    }

    func test_forecast_prunesWeatherOlderThan13Months() async {
        let old = WeatherRow(cellKey: "1,1", hourAt: net.clock - 400 * OutsideTime.dayMs, source: "open-meteo", kind: .history, windKmh: 5, fetchedAt: 0)
        let recent = WeatherRow(cellKey: "1,1", hourAt: net.clock - 300 * OutsideTime.dayMs, source: "open-meteo", kind: .history, windKmh: 5, fetchedAt: 0)
        try! store.save(weather: [old, recent])
        _ = await client().refreshForecast(lat: lat, lon: lon)
        XCTAssertNil(store.rows["1,1|\(old.hourAt)|history"])
        XCTAssertNotNil(store.rows["1,1|\(recent.hourAt)|history"])
    }

    // MARK: History backfill

    func test_backfill_fillsTheRideAndTheRainWindow_thenIsCached() async {
        let r = ride("a", daysAgo: 3)
        let c = client()
        let first = await c.backfillHistory(rides: [r])
        XCTAssertEqual(first.filled, 1)
        XCTAssertEqual(first.requests, 1)
        let cell = GeoCell.key(lat: lat, lon: lon)
        let rows = try! store.weather(cell: cell, from: 0, to: Int64.max, kind: .history)
        XCTAssertEqual(rows.count, 24)
        XCTAssertTrue(rows.allSatisfy { $0.source == "open-meteo" })
        XCTAssertTrue(rows.contains { $0.hourAt == OutsideTime.floorHour(r.startAt - 4 * OutsideTime.hourMs) })
        let again = await c.backfillHistory(rides: [r])
        XCTAssertEqual(again.alreadyCached, 1)
        XCTAssertEqual(again.requests, 0)
        XCTAssertEqual(net.urls.count, 1)
    }

    func test_backfill_oneRequestPerCellAndDay_forTwoRidesOnTheSameDay() async {
        let a = ride("a", daysAgo: 3), b = ride("b", daysAgo: 3, minutes: 20)
        let out = await client().backfillHistory(rides: [a, b])
        XCTAssertEqual(out.requests, 1)
        XCTAssertEqual(out.filled, 1)
        XCTAssertEqual(out.alreadyCached, 1)
    }

    func test_backfill_rideAcrossMidnightAsksBothDays() async {
        let startOfDay = OutsideTime.floorDay(net.clock) - 3 * OutsideTime.dayMs
        let r = BackfillRide(id: "late", startAt: startOfDay + 23 * OutsideTime.hourMs, endAt: startOfDay + 25 * OutsideTime.hourMs, lat: lat, lon: lon)
        let out = await client().backfillHistory(rides: [r])
        XCTAssertEqual(out.requests, 2)
        XCTAssertEqual(out.filled, 1)
    }

    func test_backfill_failure_isTriedOncePerDay_thenSucceedsWhenBack() async {
        net.down = ["historical-forecast-api.open-meteo.com"]
        let r = ride("a", daysAgo: 3)
        let c = client()
        let first = await c.backfillHistory(rides: [r])
        XCTAssertEqual(first.pending, 1)
        XCTAssertEqual(first.requests, 1)
        XCTAssertEqual(net.count(host: "archive-api.open-meteo.com"), 0, "a recent ride waits for the history API, the Archive API comes after 30 days")
        let same = await c.backfillHistory(rides: [r])
        XCTAssertEqual(same.pending, 1)
        XCTAssertEqual(same.requests, 0, "one try a day")
        net.down = []
        net.clock += 25 * OutsideTime.hourMs
        let later = await c.backfillHistory(rides: [r])
        XCTAssertEqual(later.filled, 1)
        XCTAssertEqual(later.requests, 1)
    }

    func test_backfill_rideOlderThan30Days_fallsToTheArchive() async {
        net.down = ["historical-forecast-api.open-meteo.com"]
        let out = await client().backfillHistory(rides: [ride("old", daysAgo: 40)])
        XCTAssertEqual(out.filled, 1)
        XCTAssertEqual(out.archiveDays, 1)
        XCTAssertEqual(out.requests, 2)
        let rows = try! store.weather(cell: GeoCell.key(lat: lat, lon: lon), from: 0, to: Int64.max, kind: .history)
        XCTAssertTrue(rows.allSatisfy { $0.source == "open-meteo-archive" })
    }

    func test_backfill_offline_leavesRidesPending_noCrash() async {
        net.offline = true
        let out = await client().backfillHistory(rides: [ride("a", daysAgo: 3), ride("b", daysAgo: 4)])
        XCTAssertEqual(out.pending, 2)
        XCTAssertEqual(out.filled, 0)
        XCTAssertTrue(store.rows.isEmpty)
    }

    func test_backfill_skipsNoGpsAndTooRecent() async {
        let justEnded = BackfillRide(id: "now", startAt: net.clock - 40 * 60_000, endAt: net.clock - 10 * 60_000, lat: lat, lon: lon)
        let out = await client().backfillHistory(rides: [ride("nogps", daysAgo: 3, gps: false), justEnded])
        XCTAssertEqual(out.skipped, 2)
        XCTAssertEqual(out.requests, 0)
    }

    func test_backfill_requestBudgetPerRun() async {
        let rides = (1...4).map { ride("r\($0)", daysAgo: Double($0) + 2) }
        let out = await client().backfillHistory(rides: rides, maxRequests: 2)
        XCTAssertEqual(out.requests, 2)
        XCTAssertEqual(out.filled, 2)
        XCTAssertEqual(out.pending, 2)
        // the newest rides come first
        XCTAssertTrue(out.pending == 2)
        let next = await client().backfillHistory(rides: rides, maxRequests: 2)
        XCTAssertEqual(next.alreadyCached, 2)
        XCTAssertEqual(next.filled, 2)
    }

    // MARK: Elevation

    func test_elevation_cachedForever_oneCallForManyCells() async {
        let cells = ["1001,-3003", "1002,-3003", "1003,-3003", "1001,-3003"]
        let c = client()
        let first = await c.elevations(cells: cells)
        XCTAssertEqual(first.fetched, 3)
        XCTAssertEqual(net.urls.count, 1)
        XCTAssertTrue(net.urls[0].absoluteString.contains("latitude=10.01,10.02,10.03"))
        XCTAssertNotNil(try! store.elevation(cell: "1002,-3003"))
        let again = await c.elevations(cells: cells)
        XCTAssertEqual(again.cached, 3)
        XCTAssertEqual(net.urls.count, 1)
    }

    func test_elevation_batchesOf100() async {
        let cells = (0..<150).map { "\(1000 + $0),-3000" }
        let out = await client().elevations(cells: cells)
        XCTAssertEqual(out.fetched, 150)
        XCTAssertEqual(net.urls.count, 2)
    }

    func test_elevation_failure_leavesNoValue_noCrash() async {
        net.offline = true
        let out = await client().elevations(cells: ["1001,-3003"])
        XCTAssertEqual(out.failed, 1)
        XCTAssertNil(try! store.elevation(cell: "1001,-3003"))
        // a wrong number of answers is a failure too
        let short = OutsideClient(store: store, fetch: { _ in OutsideSamples.elevation([1]) }, now: { 0 })
        let two = await short.elevations(cells: ["1,1", "2,2"])
        XCTAssertEqual(two.failed, 2)
    }

    // MARK: Holidays

    func test_holidays_offlineThenHebcalReplacesThem() async {
        net.offline = true
        let c = client()
        let off = await c.refreshHolidays(years: [2026, 2027])
        XCTAssertEqual(off.years[2026], "offline")
        let stored = try! store.holidays(year: 2026)
        XCTAssertFalse(stored.isEmpty)
        XCTAssertTrue(stored.allSatisfy { $0.source == "offline" })
        XCTAssertTrue(stored.contains { $0.holiday.name == "Yom Kippur" && $0.holiday.date == "2026-09-21" })
        let asked = net.urls.count
        _ = await c.refreshHolidays(years: [2026])
        XCTAssertEqual(net.urls.count, asked, "offline days are retried once a day")

        net.offline = false
        net.clock += 25 * OutsideTime.hourMs
        let on = await c.refreshHolidays(years: [2026])
        XCTAssertEqual(on.years[2026], "hebcal")
        XCTAssertTrue(try! store.holidays(year: 2026).allSatisfy { $0.source == "hebcal" })
        let before = net.urls.count
        let cached = await c.refreshHolidays(years: [2026])
        XCTAssertEqual(cached.years[2026], "cached")
        XCTAssertEqual(net.urls.count, before)
    }

    func test_offlineHolidays_matchHebcal2026() throws {
        let hebcal = try OutsideParsers.holidays(Data(contentsOf: Fixtures.url("outside/hebcal-2026.json")))
        let offline = OfflineHolidays.holidays(year: 2026)
        XCTAssertEqual(Set(offline.filter(\.isDayOff).map(\.date)), Set(hebcal.filter(\.isDayOff).map(\.date)))
        XCTAssertEqual(Set(offline.filter(\.isEveOfDayOff).map(\.date)), Set(hebcal.filter(\.isEveOfDayOff).map(\.date)))
        XCTAssertEqual(offline.filter(\.isDayOff).count, 9)
        for h in offline {
            XCTAssertTrue(hebcal.contains { $0.date == h.date && $0.kind == h.kind }, "\(h.name) \(h.date) is not in Hebcal")
        }
    }

    func test_offlineHolidays_otherYears_andIndependenceDayShift() {
        func date(_ y: Int, _ name: String) -> String? { OfflineHolidays.holidays(year: y).first { $0.baseName == name }?.date }
        XCTAssertEqual(date(2027, "Rosh Hashana"), "2027-10-02")
        XCTAssertEqual(date(2027, "Yom Kippur"), "2027-10-11")
        XCTAssertEqual(date(2027, "Pesach I"), "2027-04-22")
        XCTAssertEqual(date(2027, "Shavuot"), "2027-06-11")
        // 5 Iyar on a Monday moves to the Tuesday (2024), on a Saturday back to the Thursday (2025)
        XCTAssertEqual(date(2024, "Yom HaAtzma'ut"), "2024-05-14")
        XCTAssertEqual(date(2024, "Yom HaZikaron"), "2024-05-13")
        XCTAssertEqual(date(2025, "Yom HaAtzma'ut"), "2025-05-01")
        XCTAssertEqual(date(2025, "Yom HaZikaron"), "2025-04-30")
    }

    func test_holidayClassification_ignoresCholHamoedAndMinorDays() {
        func h(_ name: String, _ kind: Holiday.Kind = .holiday) -> Holiday { Holiday(date: "2026-01-01", name: name, kind: kind) }
        XCTAssertTrue(h("Rosh Hashana 5787").isDayOff)
        XCTAssertTrue(h("Sukkot I").isDayOff)
        XCTAssertFalse(h("Sukkot II (CH\u{2019}\u{2019}M)").isDayOff)
        XCTAssertFalse(h("Sukkot VII (Hoshana Raba)").isDayOff)
        XCTAssertFalse(h("Pesach VI (CH\u{2019}\u{2019}M)").isDayOff)
        XCTAssertFalse(h("Rosh Hashana LaBehemot").isDayOff)
        XCTAssertFalse(h("Family Day").isDayOff)
        XCTAssertTrue(h("Erev Pesach", .eve).isEveOfDayOff)
        XCTAssertFalse(h("Erev Tish\u{2019}a B\u{2019}Av", .eve).isEveOfDayOff)
    }

    func test_urls_archiveAndElevationPoints() {
        let archive = OutsideParsers.openMeteoArchiveURL(lat: 10.0123, lon: -30.0291, day: "2026-09-01").absoluteString
        XCTAssertTrue(archive.hasPrefix("https://archive-api.open-meteo.com/v1/archive?latitude=10.01&longitude=-30.03&start_date=2026-09-01"), archive)
        let points = OutsideParsers.elevationURL(points: [(10.0123, -30.0291), (10.0251, -30.0349)]).absoluteString
        XCTAssertTrue(points.hasSuffix("latitude=10.01,10.03&longitude=-30.03,-30.03"), points)
    }
}
