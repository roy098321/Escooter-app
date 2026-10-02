import Foundation

/// Parsers and validators for the outside sources (ARCHITECTURE §3). Pure Foundation, so they
/// are tested on Linux against saved sample responses. Every response is validated (ranges,
/// units) before use; a bad response counts as a failure (§3 request rules).
public struct WeatherHour: Equatable, Sendable {
    public var time: Date
    public var windKmh: Double
    public var windFromDeg: Double?
    public var gustKmh: Double?
    public var precipMm: Double?
    public var airTempC: Double?
}

public struct Holiday: Equatable, Sendable {
    public enum Kind: String, Sendable { case holiday, eve }
    public var date: String          // yyyy-MM-dd
    public var name: String
    public var kind: Kind
}

public enum OutsideParseError: Error, Equatable {
    case badJSON
    case missing(String)
    case outOfRange(String)
    case empty
}

public enum OutsideParsers {
    // MARK: Requests (the probes and P5 use the same URLs)

    /// Location is always rounded to ~2 km before it leaves the phone (ARCHITECTURE §3).
    public static func rounded(_ value: Double, step: Double = 0.02) -> Double {
        (value / step).rounded() * step
    }

    public static func openMeteoForecastURL(lat: Double, lon: Double) -> URL {
        URL(string: String(format: "https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f&hourly=wind_speed_10m,wind_direction_10m,wind_gusts_10m,precipitation,temperature_2m&forecast_days=2&timezone=UTC",
                           rounded(lat), rounded(lon)))!
    }

    public static func openMeteoHistoryURL(lat: Double, lon: Double, day: String) -> URL {
        let place = String(format: "latitude=%.2f&longitude=%.2f", rounded(lat), rounded(lon))
        return URL(string: "https://historical-forecast-api.open-meteo.com/v1/forecast?\(place)&start_date=\(day)&end_date=\(day)&hourly=wind_speed_10m,wind_direction_10m,wind_gusts_10m,precipitation,temperature_2m&timezone=UTC")!
    }

    public static func metNorwayURL(lat: Double, lon: Double) -> URL {
        URL(string: String(format: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%.2f&lon=%.2f",
                           rounded(lat), rounded(lon)))!
    }

    public static func elevationURL(lat: Double, lon: Double) -> URL {
        URL(string: String(format: "https://api.open-meteo.com/v1/elevation?latitude=%.3f&longitude=%.3f",
                           rounded(lat, step: 0.001), rounded(lon, step: 0.001)))!
    }

    public static func hebcalURL(year: Int) -> URL {
        URL(string: "https://www.hebcal.com/hebcal?v=1&cfg=json&maj=on&min=on&mod=on&i=on&year=\(year)&geo=none&c=off")!
    }

    /// Ministry of Energy monthly fuel price notice (PDF). Most months use the first name;
    /// some use the second (August 2026), so both are tried. Month = English name, lower case.
    public static func fuelPriceURLs(month: String, year: Int) -> [URL] {
        let base = "https://www.gov.il/BlobFolder/news/fuel-\(month)-\(year)/he/"
        return ["fuel-\(month)-\(year).pdf", "fuel_\(month)\(year).pdf", "fuel-\(month)\(year).pdf"]
            .compactMap { URL(string: base + $0) }
    }

    public static let englishMonths = ["january", "february", "march", "april", "may", "june", "july",
                                       "august", "september", "october", "november", "december"]

    // MARK: Open-Meteo (forecast and history share the format)

    public static func openMeteoHourly(_ data: Data) throws -> [WeatherHour] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OutsideParseError.badJSON }
        guard let hourly = root["hourly"] as? [String: Any], let times = hourly["time"] as? [String] else {
            throw OutsideParseError.missing("hourly.time")
        }
        func column(_ name: String) -> [Double?] {
            (hourly[name] as? [Any])?.map { number($0) } ?? []
        }
        let wind = column("wind_speed_10m"), dir = column("wind_direction_10m"), gust = column("wind_gusts_10m")
        let rain = column("precipitation"), temp = column("temperature_2m")
        guard wind.count == times.count else { throw OutsideParseError.missing("wind_speed_10m") }
        var out: [WeatherHour] = []
        for (i, t) in times.enumerated() {
            guard let date = parseHour(t), let w = wind[i] else { continue }
            out.append(WeatherHour(time: date, windKmh: w, windFromDeg: i < dir.count ? dir[i] : nil,
                                   gustKmh: i < gust.count ? gust[i] : nil, precipMm: i < rain.count ? rain[i] : nil,
                                   airTempC: i < temp.count ? temp[i] : nil))
        }
        try validate(out)
        return out
    }

    // MARK: MET Norway Locationforecast 2.0 compact

    public static func metNorwayHourly(_ data: Data) throws -> [WeatherHour] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OutsideParseError.badJSON }
        guard let props = root["properties"] as? [String: Any], let series = props["timeseries"] as? [[String: Any]] else {
            throw OutsideParseError.missing("properties.timeseries")
        }
        var out: [WeatherHour] = []
        for entry in series {
            guard let time = (entry["time"] as? String).flatMap(parseISO),
                  let dataObj = entry["data"] as? [String: Any],
                  let instant = (dataObj["instant"] as? [String: Any])?["details"] as? [String: Any],
                  let windMs = number(instant["wind_speed"]) else { continue }
            let next1 = (dataObj["next_1_hours"] as? [String: Any])?["details"] as? [String: Any]
            let gust = number(instant["wind_speed_of_gust"]).map { $0 * 3.6 }
            out.append(WeatherHour(time: time, windKmh: windMs * 3.6,
                                   windFromDeg: number(instant["wind_from_direction"]),
                                   gustKmh: gust,
                                   precipMm: number(next1?["precipitation_amount"]),
                                   airTempC: number(instant["air_temperature"])))
        }
        try validate(out)
        return out
    }

    // MARK: Open-Meteo Elevation (DEM)

    public static func elevations(_ data: Data) throws -> [Double] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OutsideParseError.badJSON }
        guard let values = root["elevation"] as? [Any], !values.isEmpty else { throw OutsideParseError.missing("elevation") }
        let metres = values.compactMap { number($0) }
        guard metres.count == values.count else { throw OutsideParseError.missing("elevation") }
        guard metres.allSatisfy({ (-500...9000).contains($0) }) else { throw OutsideParseError.outOfRange("elevation") }
        return metres
    }

    // MARK: Hebcal (Israel schedule)

    public static func holidays(_ data: Data) throws -> [Holiday] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OutsideParseError.badJSON }
        guard let items = root["items"] as? [[String: Any]] else { throw OutsideParseError.missing("items") }
        var out: [Holiday] = []
        for item in items where (item["category"] as? String) == "holiday" {
            guard let title = item["title"] as? String, let date = (item["date"] as? String)?.prefix(10) else { continue }
            out.append(Holiday(date: String(date), name: title, kind: title.hasPrefix("Erev ") ? .eve : .holiday))
        }
        guard !out.isEmpty else { throw OutsideParseError.empty }
        return out
    }

    // MARK: Fuel price (text of the Ministry of Energy PDF notice)

    /// The 95-octane self-service maximum price, ILS per litre, from the notice's text.
    /// Looks for "לא יעלה על <price>" (first price in the notice = 95 octane incl. VAT),
    /// then for the "total consumer price" row; the price must be 4–15 ILS.
    public static func fuelPrice95(fromText text: String) -> Double? {
        let flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let patterns = ["לא יעלה ?על ?([0-9]+\\.[0-9]{2})", "סה\"כ מחיר לצרכן ?([0-9]+\\.[0-9]{2})"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(flat.startIndex..., in: flat)
            if let match = regex.firstMatch(in: flat, range: range),
               let r = Range(match.range(at: 1), in: flat), let price = Double(flat[r]), (4.0...15.0).contains(price) {
                return price
            }
        }
        return nil
    }

    // MARK: Helpers

    /// JSON numbers come back as NSNumber on Apple platforms and as Swift numbers on Linux.
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    static func validate(_ hours: [WeatherHour]) throws {
        guard !hours.isEmpty else { throw OutsideParseError.empty }
        for h in hours {
            if !(0...250).contains(h.windKmh) { throw OutsideParseError.outOfRange("wind") }
            if let p = h.precipMm, !(0...300).contains(p) { throw OutsideParseError.outOfRange("precipitation") }
            if let t = h.airTempC, !(-60...65).contains(t) { throw OutsideParseError.outOfRange("temperature") }
            if let d = h.windFromDeg, !(0...360).contains(d) { throw OutsideParseError.outOfRange("wind direction") }
        }
    }

    /// "2026-10-02T13:00" (UTC)
    static func parseHour(_ text: String) -> Date? {
        parseISO(text + ":00Z")
    }

    static func parseISO(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
