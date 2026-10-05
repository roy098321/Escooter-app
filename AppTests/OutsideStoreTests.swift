import CorckieCore
import Foundation
import GRDB
import XCTest

/// M4-01: the outside-data cache on the real schema (migration v1, no schema change): weather, elevation, holidays,
/// the daily retry marks, and the whole client on SQLite with a fake network.
final class OutsideStoreTests: XCTestCase {
    private var folder: URL!
    private let t0: Int64 = 1_790_000_000_000
    private let hour = OutsideTime.hourMs

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("corckie-outside-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func open() throws -> AppDatabase {
        try AppDatabase(url: folder.appendingPathComponent("corckie.sqlite"), build: "t1")
    }

    private func row(_ cell: String, _ at: Int64, kind: WeatherKind = .forecast, wind: Double = 10, fetched: Int64 = 0) -> WeatherRow {
        WeatherRow(cellKey: cell, hourAt: at, source: "open-meteo", kind: kind, windKmh: wind, windFromDeg: 270, gustKmh: 20,
                   precipMm: 0.4, airTempC: 25, fetchedAt: fetched)
    }

    func test_weather_roundTrip_replaceByKey_kindsStaySeparate() throws {
        let q = OutsideQueries(try open())
        let h = OutsideTime.floorHour(t0)
        try q.save(weather: [row("1,1", h), row("1,1", h + hour), row("1,1", h, kind: .history, wind: 7), row("2,2", h)])
        let forecast = try q.weather(cell: "1,1", from: h, to: h + hour, kind: .forecast)
        XCTAssertEqual(forecast.map(\.hourAt), [h, h + hour])
        XCTAssertEqual(forecast[0].windFromDeg, 270)
        XCTAssertEqual(forecast[0].precipMm, 0.4)
        XCTAssertEqual(forecast[0].airTempC, 25)
        let history = try q.weather(cell: "1,1", from: 0, to: Int64.max, kind: .history)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].windKmh, 7)
        // the same (cell, hour, kind) is replaced, not doubled
        try q.save(weather: [row("1,1", h, wind: 33, fetched: 5)])
        let again = try q.weather(cell: "1,1", from: h, to: h, kind: .forecast)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].windKmh, 33)
        XCTAssertEqual(again[0].fetchedAt, 5)
        XCTAssertEqual(try q.weather(cell: "2,2", from: 0, to: Int64.max, kind: .forecast).count, 1)
    }

    func test_weather_nullColumnsComeBackAsNil() throws {
        let q = OutsideQueries(try open())
        try q.save(weather: [WeatherRow(cellKey: "1,1", hourAt: 3_600_000, source: "met-no", kind: .forecast, windKmh: 4, fetchedAt: 9)])
        let r = try XCTUnwrap(try q.weather(cell: "1,1", from: 0, to: Int64.max, kind: .forecast).first)
        XCTAssertNil(r.windFromDeg)
        XCTAssertNil(r.gustKmh)
        XCTAssertNil(r.precipMm)
        XCTAssertNil(r.airTempC)
        XCTAssertEqual(r.source, "met-no")
    }

    func test_prune_dropsOnlyOldHours() throws {
        let q = OutsideQueries(try open())
        try q.save(weather: [row("1,1", 1_000), row("1,1", 5_000_000)])
        try q.pruneWeather(before: 2_000)
        XCTAssertEqual(try q.weather(cell: "1,1", from: 0, to: Int64.max, kind: .forecast).map(\.hourAt), [5_000_000])
    }

    func test_elevation_cachedPerCell() throws {
        let q = OutsideQueries(try open())
        XCTAssertNil(try q.elevation(cell: "1001,-3003"))
        try q.save(elevations: ["1001,-3003": 123.5, "1002,-3003": -4], source: "open-meteo-dem")
        XCTAssertEqual(try q.elevation(cell: "1001,-3003"), 123.5)
        XCTAssertEqual(try q.elevation(cell: "1002,-3003"), -4)
        try q.save(elevations: ["1001,-3003": 130], source: "open-meteo-dem")
        XCTAssertEqual(try q.elevation(cell: "1001,-3003"), 130)
    }

    func test_holidays_replaceWholeYear_andKeepKinds() throws {
        let q = OutsideQueries(try open())
        try q.replaceHolidays(year: 2026, with: [Holiday(date: "2026-09-20", name: "Erev Yom Kippur", kind: .eve),
                                                  Holiday(date: "2026-09-21", name: "Yom Kippur", kind: .holiday)], source: "offline")
        try q.replaceHolidays(year: 2027, with: [Holiday(date: "2027-10-11", name: "Yom Kippur", kind: .holiday)], source: "hebcal")
        var y = try q.holidays(year: 2026)
        XCTAssertEqual(y.map(\.holiday.date), ["2026-09-20", "2026-09-21"])
        XCTAssertEqual(y.map(\.holiday.kind), [.eve, .holiday])
        XCTAssertTrue(y.allSatisfy { $0.source == "offline" })
        try q.replaceHolidays(year: 2026, with: [Holiday(date: "2026-09-21", name: "Yom Kippur", kind: .holiday)], source: "hebcal")
        y = try q.holidays(year: 2026)
        XCTAssertEqual(y.count, 1)
        XCTAssertEqual(y[0].source, "hebcal")
        XCTAssertEqual(try q.holidays(year: 2027).count, 1, "another year is untouched")
        let counts = try q.counts()
        XCTAssertEqual(counts.holidays, 2)
        XCTAssertEqual(counts.holidaysOffline, 0)
    }

    func test_attempts_areRemembered() throws {
        let q = OutsideQueries(try open())
        XCTAssertNil(try q.lastAttempt("history|1,1|2026-09-01"))
        try q.markAttempt("history|1,1|2026-09-01", at: 42)
        XCTAssertEqual(try q.lastAttempt("history|1,1|2026-09-01"), 42)
        try q.markAttempt("history|1,1|2026-09-01", at: 99)
        XCTAssertEqual(try q.lastAttempt("history|1,1|2026-09-01"), 99)
    }

    private func addRide(_ q: RideQueries, _ id: String, startAt: Int64, status: String = "ended", sim: Bool = false, kind: String = "ride",
                         fixes: [(Int64, Double, Double)] = []) throws {
        var r = RideRecord(id: id, startAt: startAt)
        r.endAt = startAt + 1_800_000
        r.status = status
        r.isSimulated = sim
        r.kind = kind
        try q.save(r)
        var samples: [RideSampleRecord] = []
        for (t, lat, lon) in fixes {
            var s = RideSampleRecord(rideId: id, t: t)
            s.lat = lat
            s.lon = lon
            samples.append(s)
        }
        // a sample before the first fix, without a position
        var none = RideSampleRecord(rideId: id, t: 0)
        none.lat = nil
        samples.append(none)
        try q.insert(samples: samples)
    }

    func test_backfillRides_firstFixOnly_skipsSimulatedOpenAndHops() throws {
        let db = try open()
        let rides = RideQueries(db)
        // made-up positions in the ocean
        try addRide(rides, "a", startAt: t0, fixes: [(1_000, 10.0123, -30.0291), (2_000, 10.5, -30.5)])
        try addRide(rides, "nogps", startAt: t0 + 1_000_000)
        try addRide(rides, "sim", startAt: t0 + 2_000_000, sim: true, fixes: [(1_000, 10.0, -30.0)])
        try addRide(rides, "open", startAt: t0 + 3_000_000, status: "recording", fixes: [(1_000, 10.0, -30.0)])
        try addRide(rides, "hop", startAt: t0 + 4_000_000, kind: "shortHop", fixes: [(1_000, 10.0, -30.0)])
        let out = try OutsideQueries(db).backfillRides(limit: 10)
        XCTAssertEqual(out.map(\.id), ["nogps", "a"], "newest first; simulated, still recording and short hops left out")
        let a = try XCTUnwrap(out.first { $0.id == "a" })
        XCTAssertEqual(a.lat ?? 0, 10.0123, accuracy: 1e-9)
        XCTAssertEqual(a.lon ?? 0, -30.0291, accuracy: 1e-9)
        XCTAssertEqual(a.endAt, t0 + 1_800_000)
        XCTAssertNil(out.first { $0.id == "nogps" }?.lat)
        XCTAssertEqual(try OutsideQueries(db).backfillRides(limit: 1).count, 1)
    }

    func test_rideCells_eachCellOnce_inOrder() throws {
        let db = try open()
        try addRide(RideQueries(db), "a", startAt: t0, fixes: [(1_000, 10.0101, -30.0301), (2_000, 10.0102, -30.0302), (3_000, 10.0201, -30.0301),
                                                                (4_000, 10.0102, -30.0299)])
        XCTAssertEqual(try OutsideQueries(db).rideCells(rideId: "a"), ["1001,-3003", "1002,-3003"])
    }

    func test_clientOnSQLite_everyPartFillsAndFallsBack() async throws {
        let db = try open()
        let rides = RideQueries(db)
        let start = OutsideTime.floorDay(t0) - 3 * OutsideTime.dayMs + 12 * hour
        try addRide(rides, "a", startAt: start, fixes: [(1_000, 10.0123, -30.0291), (900_000, 10.0233, -30.0291)])
        let store = OutsideQueries(db)
        let net = FakeOutsideNet(clock: t0)
        let client = OutsideClient(store: store, fetch: net.fetch, now: { net.clock })

        // forecast: Open-Meteo, cached 60 min, then MET Norway, then the old cache
        let first = await client.refreshForecast(lat: 10.0123, lon: -30.0291)
        guard case .fresh(_, "open-meteo") = first else { return XCTFail("\(first)") }
        let cell = GeoCell.key(lat: 10.0123, lon: -30.0291)
        XCTAssertGreaterThan(try store.weather(cell: cell, from: 0, to: Int64.max, kind: .forecast).count, 24)
        net.clock += 10 * 60_000
        guard case .cached = await client.refreshForecast(lat: 10.0123, lon: -30.0291) else { return XCTFail("not cached") }
        net.down = ["api.open-meteo.com"]
        net.clock += 2 * hour
        guard case .fresh(_, "met-no") = await client.refreshForecast(lat: 10.0123, lon: -30.0291) else { return XCTFail("no MET Norway") }
        net.offline = true
        net.clock += hour
        guard case .stale = await client.refreshForecast(lat: 10.0123, lon: -30.0291) else { return XCTFail("no stale cache") }
        net.offline = false
        net.down = []

        // history for the ride from the rides table, then elevation for its cells, then holidays
        let history = await client.backfillHistory(rides: try store.backfillRides(limit: 10))
        XCTAssertEqual(history.filled, 1)
        XCTAssertEqual(try store.weather(cell: cell, from: 0, to: Int64.max, kind: .history).count, 24)
        let cells = try store.rideCells(rideId: "a")
        XCTAssertEqual(cells.count, 2)
        let elevation = await client.elevations(cells: cells)
        XCTAssertEqual(elevation.fetched, 2)
        XCTAssertEqual(try store.elevation(cell: cells[0]), 100)
        let holidays = await client.refreshHolidays(years: [2026])
        XCTAssertEqual(holidays.years[2026], "hebcal")

        let counts = try store.counts()
        XCTAssertEqual(counts.historyHours, 24)
        XCTAssertGreaterThan(counts.forecastHours, 24)
        XCTAssertEqual(counts.elevationCells, 2)
        XCTAssertEqual(counts.holidays, 30)
        XCTAssertEqual(counts.weatherHours, counts.forecastHours + counts.historyHours)
    }

    func test_clientOnSQLite_offlineHolidaysUseTheCalendarAndAreMarked() async throws {
        let store = OutsideQueries(try open())
        let net = FakeOutsideNet(clock: t0)
        net.offline = true
        let out = await OutsideClient(store: store, fetch: net.fetch, now: { net.clock }).refreshHolidays(years: [2026])
        XCTAssertEqual(out.years[2026], "offline")
        XCTAssertGreaterThan(try store.counts().holidaysOffline, 10)
        XCTAssertTrue(try store.holidays(year: 2026).contains { $0.holiday.date == "2026-09-21" && $0.holiday.isDayOff })
    }
}
