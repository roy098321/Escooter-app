import CorckieCore
import Foundation
import GRDB
import Network
import Observation
import PDFKit
import UIKit

/// Outside-data probes (F09): each source of ARCHITECTURE §3 is fetched once and parsed with
/// the same parser P5 will use; each result is a check (e1–e7). Shared client rules: 10 s
/// timeout, 2 retries with back-off; a bad response counts as a failure.
@Observable
final class OutsideProbes {
    static let shared = OutsideProbes()

    struct Line: Identifiable {
        let id: String
        var status: CheckStatus
        var text: String
    }

    private(set) var running = false
    private(set) var lines: [String: Line] = [:]

    /// MET Norway and OSM require an identifying User-Agent (ARCHITECTURE §3).
    static let userAgent = "CorckieApp/\(AppInfo.version) (personal, non-commercial; github.com/roy098321)"
    /// No location yet: the fake ocean point of the fixtures (no real place is ever hard-coded).
    static let fallbackPoint = (lat: 10.0, lon: -30.0)

    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": OutsideProbes.userAgent]
        return URLSession(configuration: config)
    }()

    /// e8: is there a network path? (NWPathMonitor)
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var pathSatisfied = true
    @ObservationIgnored private var recordChecks = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathSatisfied = path.status == .satisfied
        }
        monitor.start(queue: DispatchQueue(label: "corckie.path"))
    }

    var isOffline: Bool { !pathSatisfied }

    func runAll() async {
        await MainActor.run { running = true }
        let offline = isOffline
        // Offline (e8): the probes run to show their fallbacks, without overwriting e2–e7
        recordChecks = !offline
        PhoneSensors.shared.requestOneFix()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let real = PhoneSensors.shared.roundedLocation
        let point = real ?? Self.fallbackPoint
        let where_ = real == nil ? "fallback point (no location yet)" : "your area, rounded to ~2 km"
        // e1: the fuel price is manual in v1 (owner, P4 D4 S); fuel() is kept for v2 but not called.
        await probe("e2") { try await self.hebcal() }
        await probe("e3") {
            let hours = try OutsideParsers.openMeteoHourly(try await self.get(OutsideParsers.openMeteoForecastURL(lat: point.lat, lon: point.lon)))
            return "\(hours.count) hours · now wind \(Int(hours.first?.windKmh ?? 0)) km/h · \(where_)"
        }
        await probe("e4") {
            let hours = try OutsideParsers.metNorwayHourly(try await self.get(OutsideParsers.metNorwayURL(lat: point.lat, lon: point.lon)))
            return "\(hours.count) hours · wind \(Int(hours.first?.windKmh ?? 0)) km/h"
        }
        await probe("e5") {
            let day = Self.dayString(Date().addingTimeInterval(-86_400))
            let hours = try OutsideParsers.openMeteoHourly(try await self.get(OutsideParsers.openMeteoHistoryURL(lat: point.lat, lon: point.lon, day: day)))
            return "\(hours.count) hours for \(day)"
        }
        await probe("e6") {
            let metres = try OutsideParsers.elevations(try await self.get(OutsideParsers.elevationURL(lat: point.lat, lon: point.lon)))
            return "Elevation \(Int(metres.first ?? 0)) m"
        }
        await probe("e7") { try await self.tiles() }
        if !offline {
            if let real {
                await probe("e3b") {
                    let hours = try OutsideParsers.openMeteoHourly(try await self.get(OutsideParsers.openMeteoForecastURL(lat: real.lat, lon: real.lon)))
                    return "\(hours.count) hours for your area (rounded to ~2 km) · wind \(Int(hours.first?.windKmh ?? 0)) km/h"
                }
                await probe("e6b") {
                    let metres = try OutsideParsers.elevations(try await self.get(OutsideParsers.elevationURL(lat: real.lat, lon: real.lon)))
                    return "Elevation \(Int(metres.first ?? 0)) m for your area"
                }
            } else {
                await MainActor.run {
                    for id in ["e3b", "e6b"] {
                        CheckResults.shared.set(id, .fail, "No location yet: the fallback point was used · Permissions → Location, then Run all again")
                    }
                }
            }
        }
        await MainActor.run {
            if offline {
                let ran = ["e2", "e3", "e4", "e5", "e6", "e7"]
                let fellBack = ran.filter { lines[$0]?.status == .fail }
                CheckResults.shared.set("e8", fellBack.count == ran.count ? .pass : .info,
                                        "Offline: \(fellBack.count) of \(ran.count) sources showed their fallback, no crash"
                                        + (fellBack.count == ran.count ? "" : " (some still answered: the network came back?)"))
            }
            recordChecks = true
            running = false
        }
    }

    func report() -> String {
        var out = "Outside data probes · \(Date().formatted())\nUser-Agent: \(Self.userAgent)\n"
        // B02: details survive a relaunch — they're kept with the check result.
        let results = CheckResults.shared
        for item in CheckList.all where item.group == CheckList.outside {
            // The saved check result wins (an offline e8 run doesn't overwrite e2–e7)
            let saved = results.status(item.id)
            let status: CheckStatus = saved != .pending ? saved : (lines[item.id]?.status ?? .pending)
            let note = results.note(item.id)
            let text: String = note.isEmpty ? (lines[item.id]?.text ?? "not run") : note
            let when: String = results.entries[item.id].map { " (\($0.date.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
            out += "\(status.icon) \(item.id) \(item.title): \(text)\(when)\n"
        }
        return out
    }

    // MARK: Probes

    private func probe(_ id: String, _ work: @escaping () async throws -> String) async {
        await MainActor.run { lines[id] = Line(id: id, status: .pending, text: "Running…") }
        do {
            let text = try await work()
            await MainActor.run {
                lines[id] = Line(id: id, status: .pass, text: text)
                if recordChecks { CheckResults.shared.set(id, .pass, text) }
            }
        } catch {
            let text = "Failed: \(error.localizedDescription) · fallback: \(Self.fallback(id))"
            Log.warning(source: "outside", "\(id) \(text)")
            await MainActor.run {
                lines[id] = Line(id: id, status: .fail, text: text)
                if recordChecks { CheckResults.shared.set(id, .fail, text) }
            }
        }
    }

    private func fuel() async throws -> String {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let month = OutsideParsers.englishMonths[calendar.component(.month, from: now) - 1]
        let year = calendar.component(.year, from: now)
        var lastError: Error = URLError(.fileDoesNotExist)
        for url in OutsideParsers.fuelPriceURLs(month: month, year: year) {
            do {
                let data = try await get(url)
                guard let text = PDFDocument(data: data)?.string else { throw URLError(.cannotDecodeContentData) }
                guard let price = OutsideParsers.fuelPrice95(fromText: text) else {
                    throw NSError(domain: "corckie.fuel", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "price not found in \(url.lastPathComponent)"])
                }
                store(fuel: price, month: String(format: "%04ld-%02ld", year, calendar.component(.month, from: now)))
                return String(format: "%.2f ILS/litre for %@ %ld · %@", price, month.capitalized, year, url.lastPathComponent)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func hebcal() async throws -> String {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let days = try OutsideParsers.holidays(try await get(OutsideParsers.hebcalURL(year: year)))
        store(holidays: days)
        let next = days.first { $0.date >= Self.dayString(Date()) }
        return "\(days.count) days in \(year)" + (next.map { " · next: \($0.name) \($0.date)" } ?? "")
    }

    private func tiles() async throws -> String {
        var found: [String] = []
        for (name, address) in [("CARTO", "https://a.basemaps.cartocdn.com/light_all/3/4/3.png"),
                                ("OSM", "https://tile.openstreetmap.org/3/4/3.png")] {
            guard let url = URL(string: address) else { continue }
            let data = try await get(url)
            guard UIImage(data: data) != nil else { throw URLError(.cannotDecodeContentData) }
            found.append("\(name) \(data.count / 1024) KB")
        }
        return found.joined(separator: " · ")
    }

    // MARK: Client

    /// GET with 2 retries and back-off (1 s, 2 s); any non-2xx is a failure.
    private func get(_ url: URL) async throws -> Data {
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
            }
        }
        throw lastError
    }

    // MARK: Cache (DATA_MODEL outside-data tables)

    private func store(fuel price: Double, month: String) {
        guard let db = AppModel.shared.database, !db.isReadOnly else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? db.writer.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO fuel_price (month, priceIls, source, fetchedAt) VALUES (?, ?, 'auto', ?)",
                          arguments: [month, price, now])
        }
    }

    private func store(holidays: [Holiday]) {
        guard let db = AppModel.shared.database, !db.isReadOnly else { return }
        try? db.writer.write { d in
            for h in holidays {
                try d.execute(sql: "INSERT OR REPLACE INTO holiday (date, kind, name, source) VALUES (?, ?, ?, 'hebcal')",
                              arguments: [h.date, h.kind.rawValue, h.name])
            }
        }
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The decided fallback per source (ARCHITECTURE §4).
    static func fallback(_ id: String) -> String {
        switch id {
        case "e1": return "last known price, then the manual price (M35b)"
        case "e2": return "offline Hebrew-calendar holidays"
        case "e3": return "MET Norway, then the cached forecast with its age"
        case "e4": return "cached forecast up to 24 h old, else no forecast"
        case "e5": return "retry daily for 30 days, then the Archive API"
        case "e6": return "barometer-only elevation, shown with \"~\""
        case "e7": return "OSM after CARTO, else a replay without a map background"
        case "e3b": return "the forecast for the fallback point is not used; no forecast"
        case "e6b": return "barometer-only elevation"
        default: return "—"
        }
    }
}
