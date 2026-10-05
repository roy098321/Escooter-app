import CorckieCore
import Foundation

/// The one HTTP client of the outside data (ARCHITECTURE section 3 request rules): 10 s timeout, 2 retries with
/// back-off (1 s, 2 s), any non-2xx is a failure, an identifying User-Agent. Offline = an immediate failure, so the
/// fallbacks (MET Norway, cache, offline holidays, skip) run at once without waiting for time-outs.
enum OutsideHTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": OutsideProbes.userAgent]
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL) async throws -> Data {
        if OutsideProbes.shared.isOffline { throw URLError(.notConnectedToInternet) }
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            do {
                let (data, response) = try await session.data(from: url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    throw NSError(domain: "corckie.http", code: code,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) from \(url.host ?? "")"])
                }
                return data
            } catch {
                lastError = error
                if (error as? URLError)?.code == .notConnectedToInternet { break }
            }
        }
        throw lastError
    }
}

/// M4-01: keeps the outside-data cache filled, by itself, with only a ~1 km cell ever sent (policy P-2).
/// Runs at app open / when the app comes forward and after every ride: holidays (this and next year), the forecast
/// for the phone's rounded location, weather history for past rides, map elevation for the newest rides' cells.
/// Every part has its fallback in Core's `OutsideClient`; nothing here can crash or block the ride.
final class OutsideDataService: @unchecked Sendable {
    static let shared = OutsideDataService()

    private let lock = NSLock()
    private var running = false
    private var lastStart = Date.distantPast
    private var summary = "Not run yet"
    private var summaryAt: Date?

    private init() {}

    /// The last run in one line (for the Developer screen and check e9).
    var lastRun: (text: String, at: Date?) {
        lock.lock()
        defer { lock.unlock() }
        return (summary, summaryAt)
    }

    /// Fire and forget. App-open runs are spaced 10 min apart; a ride end always runs.
    func refresh(database: AppDatabase?, reason: String) {
        guard let database, !database.isReadOnly else { return }
        if tooSoon(reason) { return }
        Task.detached(priority: .utility) { _ = await OutsideDataService.shared.runNow(database: database, reason: reason) }
    }

    /// Runs one refresh and returns the summary line.
    @discardableResult
    func runNow(database: AppDatabase, reason: String) async -> String {
        guard begin() else { return "Already running" }

        let store = OutsideQueries(database)
        let client = OutsideClient(store: store, fetch: { try await OutsideHTTP.get($0) },
                                   now: { Int64(Date().timeIntervalSince1970 * 1000) })
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        var parts: [String] = []

        let holidays = await client.refreshHolidays(years: [year, year + 1])
        parts.append("Holidays " + holidays.years.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        var location = await MainActor.run { PhoneSensors.shared.roundedLocation }
        if location == nil {
            await MainActor.run { PhoneSensors.shared.requestOneFix() }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            location = await MainActor.run { PhoneSensors.shared.roundedLocation }
        }
        if let location {
            parts.append((await client.refreshForecast(lat: location.lat, lon: location.lon)).text)
        } else {
            parts.append("No forecast (no location yet)")
        }

        let rides = (try? store.backfillRides(limit: 40)) ?? []
        let history = await client.backfillHistory(rides: rides)
        parts.append("History: \(history.filled) filled, \(history.alreadyCached) cached, \(history.pending) waiting, \(history.skipped) skipped"
                     + (history.archiveDays > 0 ? ", \(history.archiveDays) from the archive" : ""))

        var cells: [String] = []
        for ride in rides.prefix(5) where ride.lat != nil {
            cells += (try? store.rideCells(rideId: ride.id)) ?? []
        }
        let elevation = await client.elevations(cells: cells)
        parts.append("Elevation: \(elevation.fetched) new, \(elevation.cached) cached" + (elevation.failed > 0 ? ", \(elevation.failed) failed" : ""))

        // M4-02: weather may have arrived for rides that waited (pattern W): fill their columns, rebuild the effects
        if !database.isReadOnly {
            do {
                parts.append(try FactorUpdater.refreshPending(database).text)
            } catch {
                parts.append("Factors: \(error.localizedDescription)")
            }
            // M4-03: the week cards at app open (Q22, Q4-weekly, Q13-weekly), with the weather that just came in
            if let r = try? InsightRunner.weekly(database) { parts.append("Week " + r.text) }
            BudgetedNotifier.refreshWeekly(database)
        }

        let text = parts.joined(separator: " · ")
        Log.info(source: "outside", "Refresh (\(reason)): \(text)")
        finish(text)
        return text
    }

    // The lock is only held in these small synchronous helpers (never across an await).
    private func tooSoon(_ reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reason != "ride closed" && Date().timeIntervalSince(lastStart) < 600
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { return false }
        running = true
        lastStart = Date()
        return true
    }

    private func finish(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        summary = text
        summaryAt = Date()
        running = false
    }
}

/// What the cache holds, in one line (Developer → Outside data, check e9, the end of check u30).
enum OutsideCacheSummary {
    static func text(_ database: AppDatabase?) -> String {
        guard let database, let c = try? OutsideQueries(database).counts() else { return "no data" }
        return "weather \(c.forecastHours) forecast + \(c.historyHours) history hours, elevation \(c.elevationCells) cells, holidays \(c.holidays)"
            + (c.holidaysOffline > 0 ? " (\(c.holidaysOffline) from the offline calendar)" : "")
    }
}
