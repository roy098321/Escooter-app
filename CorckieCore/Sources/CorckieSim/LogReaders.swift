import CorckieCore
import Foundation

/// Readers for every log format the fake scooter replays (TESTING §2 "Readers").
/// Lines starting with "#" (the anonymised-fixture header) are skipped.
public enum LogFormat: String, Sendable {
    /// P2 Lab / CorckieApp packet log: time,step,app_state,bytes
    case packetLog
    /// nRF Connect log: Timestamp,Source,Level,Line
    case nrfConnect
    /// 1-per-second merged ride: time,lat,lon,gps_speed_kmh,scooter_speed_kmh,...
    case mergedSamples
    /// Sensor Logger Location.csv
    case sensorLoggerLocation
    /// Sensor Logger Barometer.csv
    case sensorLoggerBarometer

    public static func detect(header: String) -> LogFormat? {
        let h = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("time,step,app_state,bytes") { return .packetLog }
        if h.hasPrefix("timestamp,source,level,line") { return .nrfConnect }
        if h.hasPrefix("time,lat,lon,") { return .mergedSamples }
        if h.hasPrefix("time,seconds_elapsed,") && h.contains("latitude") { return .sensorLoggerLocation }
        if h.hasPrefix("time,seconds_elapsed,relativealtitude") { return .sensorLoggerBarometer }
        return nil
    }
}

/// Raw scooter events of a log; t = seconds since the log's first row.
public struct ScooterLog: Sendable {
    public var format: LogFormat
    public var events: [TimedScooterEvent]
    /// Time of day of the first row, seconds after midnight (when the log has it)
    public var startTimeOfDayS: Double?

    public var packets: [[UInt8]] { events.compactMap(\.bytes) }
    public var durationS: Double { events.last?.t ?? 0 }
}

/// One row of a 1-per-second merged ride log (F3).
public struct MergedSample: Equatable, Sendable {
    public var t: Double
    public var lat: Double?
    public var lon: Double?
    public var gpsSpeedKmh: Double?
    public var scooterSpeedKmh: Double?
    public var elevBaroM: Double?
    public var voltage: Double?
    public var currentA: Double?
    public var batteryPct: Int?
    public var temperatureC: Double?
    public var brake: Bool
    public var headlight: Bool
    public var odometerKm: Double?
}

public enum LogReaderError: Error, Equatable {
    case empty
    case unknownFormat(String)
    case wrongFormat(expected: LogFormat, found: LogFormat)
}

public enum LogReader {
    // MARK: Entry points

    /// Data lines (no "#" header lines, no blank lines); first is the column header.
    static func lines(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }

    public static func format(of text: String) throws -> LogFormat {
        guard let header = lines(text).first else { throw LogReaderError.empty }
        let clean = String(header).replacingOccurrences(of: "\u{FEFF}", with: "")
        guard let format = LogFormat.detect(header: clean) else { throw LogReaderError.unknownFormat(String(clean.prefix(60))) }
        return format
    }

    /// Scooter packets and connect / disconnect events from a packet log or an nRF log.
    public static func scooterLog(_ text: String) throws -> ScooterLog {
        switch try format(of: text) {
        case .packetLog: return packetLog(text)
        case .nrfConnect: return nrfLog(text)
        case let other: throw LogReaderError.wrongFormat(expected: .packetLog, found: other)
        }
    }

    // MARK: Packet log (P2 Lab / CorckieApp export)

    static func packetLog(_ text: String) -> ScooterLog {
        var events: [TimedScooterEvent] = []
        var first: Double?
        var startOfDay: Double?
        for line in lines(text).dropFirst() {
            let cols = csvFields(line)
            guard cols.count >= 4, let abs = isoSeconds(cols[0]), let bytes = Hex.bytes(cols[3]) else { continue }
            if first == nil {
                first = abs
                startOfDay = timeOfDay(fromISO: cols[0])
            }
            events.append(TimedScooterEvent(t: abs - (first ?? abs), event: .packet(bytes)))
        }
        return ScooterLog(format: .packetLog, events: events, startTimeOfDayS: startOfDay)
    }

    // MARK: nRF Connect log

    static let nrfPacketPrefix = "Updated Value of Characteristic FFF2 to "

    static func nrfLog(_ text: String) -> ScooterLog {
        var events: [TimedScooterEvent] = []
        var clock = DayClock()
        for line in lines(text).dropFirst() {
            let cols = csvFields(line)
            guard cols.count >= 4, let tod = timeOfDay(cols[0]) else { continue }
            let message = cols[3]
            let event: ScooterEvent
            if message.hasPrefix(nrfPacketPrefix) {
                var hex = String(message.dropFirst(nrfPacketPrefix.count))
                if hex.hasSuffix(".") { hex.removeLast() }
                guard let bytes = Hex.bytes(hex) else { continue }
                event = .packet(bytes)
            } else if message == "Connected." {
                event = .connected
            } else if message == "Disconnected." {
                event = .disconnected
            } else {
                continue
            }
            events.append(TimedScooterEvent(t: clock.elapsed(timeOfDay: tod), event: event))
        }
        return ScooterLog(format: .nrfConnect, events: events, startTimeOfDayS: clock.start)
    }

    // MARK: Merged 1-per-second samples

    public static func mergedSamples(_ text: String) throws -> [MergedSample] {
        let f = try format(of: text)
        guard f == .mergedSamples else { throw LogReaderError.wrongFormat(expected: .mergedSamples, found: f) }
        let all = lines(text)
        let header = csvFields(all[0]).map { $0.replacingOccurrences(of: "\u{FEFF}", with: "") }
        func col(_ name: String) -> Int? { header.firstIndex(of: name) }
        let iTime = col("time"), iLat = col("lat"), iLon = col("lon"), iGps = col("gps_speed_kmh")
        let iSpd = col("scooter_speed_kmh"), iElev = col("elev_baro_m"), iV = col("voltage_V")
        let iI = col("current_A"), iBat = col("battery_pct"), iTemp = col("temp_C")
        let iBrake = col("brake"), iLight = col("headlight"), iOdo = col("odometer_km")
        var clock = DayClock()
        var out: [MergedSample] = []
        for line in all.dropFirst() {
            let c = csvFields(line)
            func num(_ i: Int?) -> Double? {
                guard let i, i < c.count else { return nil }
                return Double(c[i])
            }
            guard let it = iTime, it < c.count, let tod = timeOfDay(c[it]) else { continue }
            out.append(MergedSample(
                t: clock.elapsed(timeOfDay: tod),
                lat: num(iLat), lon: num(iLon), gpsSpeedKmh: num(iGps), scooterSpeedKmh: num(iSpd),
                elevBaroM: num(iElev), voltage: num(iV), currentA: num(iI),
                batteryPct: num(iBat).map { Int($0) }, temperatureC: num(iTemp),
                brake: (num(iBrake) ?? 0) != 0, headlight: (num(iLight) ?? 0) != 0, odometerKm: num(iOdo)))
        }
        return out
    }

    // MARK: Sensor Logger

    public static func sensorLoggerLocation(_ text: String) throws -> [PhoneFix] {
        let f = try format(of: text)
        guard f == .sensorLoggerLocation else { throw LogReaderError.wrongFormat(expected: .sensorLoggerLocation, found: f) }
        let all = lines(text)
        let header = csvFields(all[0])
        func col(_ name: String) -> Int { header.firstIndex(of: name) ?? -1 }
        let iE = col("seconds_elapsed"), iLat = col("latitude"), iLon = col("longitude")
        let iAcc = col("horizontalAccuracy"), iSpeed = col("speed"), iBearing = col("bearing"), iAlt = col("altitude")
        var fixes: [PhoneFix] = []
        for line in all.dropFirst() {
            let c = csvFields(line)
            func num(_ i: Int) -> Double? { i >= 0 && i < c.count ? Double(c[i]) : nil }
            guard let t = num(iE), let lat = num(iLat), let lon = num(iLon) else { continue }
            fixes.append(PhoneFix(t: t, lat: lat, lon: lon, hAccM: num(iAcc) ?? -1, speedMps: num(iSpeed) ?? -1,
                                  courseDeg: num(iBearing) ?? -1, altitudeM: num(iAlt)))
        }
        return fixes
    }

    public static func sensorLoggerBarometer(_ text: String) throws -> [BaroReading] {
        let f = try format(of: text)
        guard f == .sensorLoggerBarometer else { throw LogReaderError.wrongFormat(expected: .sensorLoggerBarometer, found: f) }
        var out: [BaroReading] = []
        for line in lines(text).dropFirst() {
            let c = csvFields(line)
            guard c.count >= 4, let t = Double(c[1]), let rel = Double(c[2]) else { continue }
            out.append(BaroReading(t: t, relativeAltitudeM: rel, pressureKPa: Double(c[3]).map { $0 / 10 }))
        }
        return out
    }

    /// Sensor Logger: the epoch second at which seconds_elapsed is 0 (first row's time minus its offset).
    public static func sensorLoggerEpochZeroS(_ text: String) -> Double? {
        let all = lines(text)
        guard all.count > 1 else { return nil }
        let header = csvFields(all[0])
        guard let iTime = header.firstIndex(of: "time"), let iElapsed = header.firstIndex(of: "seconds_elapsed") else { return nil }
        let c = csvFields(all[1])
        guard iTime < c.count, iElapsed < c.count, let ns = Double(c[iTime]), let elapsed = Double(c[iElapsed]) else { return nil }
        return ns / 1e9 - elapsed
    }

    /// 1-per-second merged log: time of day of the first row, seconds after midnight.
    public static func mergedStartTimeOfDayS(_ text: String) -> Double? {
        let all = lines(text)
        guard all.count > 1, let first = csvFields(all[1]).first else { return nil }
        return timeOfDay(first)
    }

    // MARK: Helpers

    /// Splits one CSV line; handles quoted fields with "" escapes (nRF lines are quoted).
    public static func csvFields<S: StringProtocol>(_ line: S) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = line.makeIterator()
        var pending: Character? = nil
        while true {
            let ch: Character
            if let p = pending { ch = p; pending = nil } else if let n = iterator.next() { ch = n } else { break }
            if quoted {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "," {
                fields.append(field)
                field = ""
            } else if ch == "\"" && field.isEmpty {
                quoted = true
            } else {
                field.append(ch)
            }
        }
        fields.append(field)
        return fields
    }

    /// "15:47:28.995" or "17:37:43" -> seconds after midnight.
    static func timeOfDay<S: StringProtocol>(_ text: S) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// "2000-01-01T08:17:30.072Z" -> seconds after midnight (UTC).
    static func timeOfDay(fromISO text: String) -> Double? {
        guard let tIndex = text.firstIndex(of: "T") else { return nil }
        let rest = text[text.index(after: tIndex)...].prefix { $0 != "Z" && $0 != "+" }
        return timeOfDay(rest)
    }

    /// ISO 8601 with or without fractional seconds -> seconds since 1970.
    static func isoSeconds(_ text: String) -> Double? {
        if let d = isoFractional.date(from: text) { return d.timeIntervalSince1970 }
        return isoWhole.date(from: text)?.timeIntervalSince1970
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Turns times of day into seconds since the first one, across midnight.
struct DayClock {
    private(set) var start: Double?
    private var last: Double?
    private var dayOffset = 0.0

    mutating func elapsed(timeOfDay tod: Double) -> Double {
        if start == nil { start = tod }
        if let l = last, tod + 12 * 3600 < l { dayOffset += 86_400 }   // wrapped past midnight
        last = tod
        return tod + dayOffset - (start ?? tod)
    }
}
