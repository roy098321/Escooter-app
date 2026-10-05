import Foundation

/// Small made-up responses in the formats of the real sources, for the Core tests and the in-app check u30 (no network,
/// no real place). Same shapes the parsers read from the saved real responses.
public enum OutsideSamples {
    private static func iso(_ ms: Int64, seconds: Bool) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour], from: d)
        let base = String(format: "%04ld-%02ld-%02ldT%02ld:00", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
        return seconds ? base + ":00Z" : base
    }

    /// Open-Meteo hourly JSON (forecast and history share it): `hours` hours from `fromHourMs`.
    public static func openMeteo(fromHourMs: Int64, hours: Int, windKmh: Double = 12, tempC: Double = 24) -> Data {
        let times = (0..<hours).map { "\"\(iso(fromHourMs + Int64($0) * OutsideTime.hourMs, seconds: false))\"" }.joined(separator: ",")
        func column(_ v: Double) -> String { (0..<hours).map { _ in String(v) }.joined(separator: ",") }
        let json = "{\"hourly\":{\"time\":[\(times)],\"wind_speed_10m\":[\(column(windKmh))],\"wind_direction_10m\":[\(column(270))],"
            + "\"wind_gusts_10m\":[\(column(windKmh * 1.5))],\"precipitation\":[\(column(0))],\"temperature_2m\":[\(column(tempC))]}}"
        return Data(json.utf8)
    }

    /// MET Norway compact JSON (wind in m/s).
    public static func metNorway(fromHourMs: Int64, hours: Int, windMs: Double = 3) -> Data {
        let entries = (0..<hours).map { i -> String in
            "{\"time\":\"\(iso(fromHourMs + Int64(i) * OutsideTime.hourMs, seconds: true))\",\"data\":{\"instant\":{\"details\":"
                + "{\"wind_speed\":\(windMs),\"wind_from_direction\":270,\"air_temperature\":22}},"
                + "\"next_1_hours\":{\"details\":{\"precipitation_amount\":0}}}}"
        }.joined(separator: ",")
        return Data("{\"properties\":{\"timeseries\":[\(entries)]}}".utf8)
    }

    /// Open-Meteo elevation JSON: one value per point.
    public static func elevation(_ metres: [Double]) -> Data {
        Data("{\"elevation\":[\(metres.map { String($0) }.joined(separator: ","))]}".utf8)
    }

    /// Hebcal JSON with `count` made-up holiday days in the year (the real list has ~100 with the minor days).
    public static func hebcal(year: Int, count: Int = 30) -> Data {
        let items = (0..<count).map { i in
            "{\"category\":\"holiday\",\"title\":\"Test day \(i)\",\"date\":\"\(String(format: "%04ld-%02ld-%02ld", year, 1 + i / 28, 1 + i % 28))\"}"
        }.joined(separator: ",")
        return Data("{\"items\":[\(items)]}".utf8)
    }
}

/// A fake network for the tests and the in-app check u30: answers by host with the samples above, records every URL,
/// and can be told which hosts are down or that the phone is offline.
public final class FakeOutsideNet {
    public struct Down: Error {}
    public var urls: [URL] = []
    public var down: Set<String> = []
    public var offline = false
    /// "now", epoch ms (the test moves it)
    public var clock: Int64

    public init(clock: Int64 = 1_790_000_000_000) {
        self.clock = clock
    }

    public var fetch: OutsideClient.Fetch { { [self] url in try self.answer(url) } }

    public func count(host: String) -> Int { urls.filter { $0.host == host }.count }

    func answer(_ url: URL) throws -> Data {
        urls.append(url)
        if offline { throw Down() }
        let host = url.host ?? ""
        if down.contains(host) { throw Down() }
        func param(_ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
        switch host {
        case "api.open-meteo.com" where url.path.hasSuffix("/forecast"):
            return OutsideSamples.openMeteo(fromHourMs: OutsideTime.floorDay(clock), hours: 48)
        case "api.open-meteo.com":
            return OutsideSamples.elevation((0..<(param("latitude") ?? "").split(separator: ",").count).map { Double($0) + 100 })
        case "historical-forecast-api.open-meteo.com", "archive-api.open-meteo.com":
            let day = param("start_date") ?? ""
            let ms = (OutsideParsers.parseISO(day + "T00:00:00Z")?.timeIntervalSince1970).map { Int64($0 * 1000) } ?? 0
            return OutsideSamples.openMeteo(fromHourMs: ms, hours: 24)
        case "api.met.no":
            return OutsideSamples.metNorway(fromHourMs: OutsideTime.floorHour(clock), hours: 60)
        case "www.hebcal.com":
            return OutsideSamples.hebcal(year: Int(param("year") ?? "") ?? 2026)
        default:
            throw Down()
        }
    }
}
