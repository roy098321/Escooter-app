import CorckieCore
import Foundation

/// u30 (M4-01): the outside-data cache and its fallbacks, on a fake network and made-up places (a point in the ocean)
/// in a temporary database with the real tables. Nothing is sent. The line ends with this phone's real cache.
enum OutsideDataCheck {
    static func run(real: AppDatabase?) async {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u30", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        let store = OutsideQueries(temp)
        let net = FakeOutsideNet()
        let client = OutsideClient(store: store, fetch: net.fetch, now: { net.clock })
        let lat = 10.01234, lon = -30.02912
        let hour = OutsideTime.hourMs

        // forecast: fetched, then served from the cache for 60 min
        let first = await client.refreshForecast(lat: lat, lon: lon)
        net.clock += 30 * 60_000
        let second = await client.refreshForecast(lat: lat, lon: lon)
        var freshOk = false
        if case .fresh(_, "open-meteo") = first, case .cached = second, net.urls.count == 1 { freshOk = true }

        // Open-Meteo down: MET Norway; both down: the cache with its age, then nothing after 24 h
        net.down = ["api.open-meteo.com"]
        net.clock += 2 * hour
        var metOk = false
        if case .fresh(_, "met-no") = await client.refreshForecast(lat: lat, lon: lon) { metOk = true }
        net.offline = true
        net.clock += 3 * hour
        var staleOk = false
        if case .stale = await client.refreshForecast(lat: lat, lon: lon) { staleOk = true }
        net.clock += 22 * hour
        let gone = await client.refreshForecast(lat: lat, lon: lon)
        net.offline = false
        net.down = []

        // history for past rides: filled once, cached, retried daily, the archive after 30 days
        let day = OutsideTime.dayMs
        let start = OutsideTime.floorDay(net.clock) - 3 * day + 12 * hour
        let ride = BackfillRide(id: "a", startAt: start, endAt: start + 30 * 60_000, lat: lat, lon: lon)
        let filled = await client.backfillHistory(rides: [ride])
        let cached = await client.backfillHistory(rides: [ride])
        let oldStart = OutsideTime.floorDay(net.clock) - 40 * day + 12 * hour
        let old = BackfillRide(id: "o", startAt: oldStart, endAt: oldStart + 30 * 60_000, lat: lat, lon: lon)
        net.down = ["historical-forecast-api.open-meteo.com"]
        let archive = await client.backfillHistory(rides: [old])
        let newStart = start - 5 * day
        let waiting = BackfillRide(id: "w", startAt: newStart, endAt: newStart + 30 * 60_000, lat: lat, lon: lon)
        let pending = await client.backfillHistory(rides: [waiting])
        let throttled = await client.backfillHistory(rides: [waiting])
        net.down = []
        let historyOk = filled.filled == 1 && filled.requests == 1 && cached.alreadyCached == 1 && cached.requests == 0
            && archive.filled == 1 && archive.archiveDays == 1 && pending.pending == 1 && throttled.requests == 0

        // elevation: one call for many cells, then cached forever
        let cells = ["1001,-3003", "1002,-3003", "1003,-3003"]
        let before = net.urls.count
        let e1 = await client.elevations(cells: cells)
        let e2 = await client.elevations(cells: cells)
        let elevOk = e1.fetched == 3 && e2.cached == 3 && net.urls.count == before + 1

        // holidays: offline calendar first, Hebcal replaces it
        net.offline = true
        let off = await client.refreshHolidays(years: [2026])
        let offlineRows = (try? store.holidays(year: 2026)) ?? []
        net.offline = false
        net.clock += 25 * hour
        let on = await client.refreshHolidays(years: [2026])
        let holidaysOk = off.years[2026] == "offline" && offlineRows.contains { $0.holiday.name == "Yom Kippur" && $0.holiday.date == "2026-09-21" }
            && on.years[2026] == "hebcal" && ((try? store.holidays(year: 2026)) ?? []).allSatisfy { $0.source == "hebcal" }

        // nothing sent finer than the 0.01 degree cell
        let fine = try? NSRegularExpression(pattern: "(latitude|longitude|lat|lon)=[-0-9.,]*-?\\d+\\.\\d{3,}")
        let coarse = !net.urls.isEmpty && net.urls.allSatisfy { url in
            let s = url.absoluteString
            return fine?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil
        }
        let cellOk = GeoCell.key(lat: 10.0123, lon: -30.0291) == GeoCell.key(lat: 10.0149, lon: -30.0251)

        let ok = freshOk && metOk && staleOk && gone == .none && historyOk && elevOk && holidaysOk && coarse && cellOk
        func word(_ b: Bool) -> String { b ? "ok" : "wrong" }
        results.set("u30", ok ? .pass : .fail,
                    "forecast cached 60 min \(word(freshOk)) · MET Norway when Open-Meteo is down \(word(metOk)) · old cache with its age \(word(staleOk)), none after 24 h \(word(gone == .none)) · "
                    + "history filled / cached / retried daily / archive after 30 days \(word(historyOk)) · elevation one call, cached \(word(elevOk)) · "
                    + "holidays offline then Hebcal \(word(holidaysOk)) · only a ~1 km cell sent \(word(coarse && cellOk)) · this phone: \(OutsideCacheSummary.text(real))")
    }
}
