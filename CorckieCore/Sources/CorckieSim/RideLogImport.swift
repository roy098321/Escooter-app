import CorckieCore
import Foundation

/// Import ride logs: turns log files recorded before 1.0 into one timed stream per ride, on the real clock (epoch seconds),
/// ready for the real Recorder. Pure Foundation, tested on Linux with the anonymised fixtures.
///
/// Accepted (recognised by their first line, the file names do not matter):
///  - 0.4 c8 set: `time,step,app_state,bytes` (c8-scooter-packets.csv), optional `time,lat,lon,speed_mps,h_accuracy_m,altitude_m,course_deg`
///    (c8-location.csv) and `time,relative_altitude_m,pressure_kpa` (c8-barometer.csv); every time is ISO 8601 with the date.
///  - nRF Connect log export `Timestamp,Source,Level,Line` (time of day only: the date comes from a Sensor Logger file of the same
///    ride, else from the log file's own date) + optional Sensor Logger `Location.csv` / `Barometer.csv`.
public struct ImportFileText: Sendable {
    public var name: String
    public var text: String
    /// When the file was saved (the date of an nRF log that has no Sensor Logger file next to it)
    public var modified: Date?

    public init(name: String, text: String, modified: Date? = nil) {
        self.name = name
        self.text = text
        self.modified = modified
    }
}

public struct ImportedRideLog: Sendable {
    /// Every time is epoch seconds
    public var stream: SimStream
    public var startEpoch: Double
    public var utcOffsetMin: Int
    /// "c8" or "nRF Connect"
    public var source: String
    public var fileNames: [String]
    public var notes: [String]

    /// The Recorder's input list (a tick every second, `tailS` of ticks after the last row so the ride can end).
    public func inputs(tailS: Double = 1_800) -> [(t: Double, input: RecorderInput)] {
        RecorderRunner.inputs(stream, tailS: tailS)
    }
}

public enum RideLogImportError: Error, Equatable, LocalizedError {
    case noScooterLog
    case needsDate(String)

    public var errorDescription: String? {
        switch self {
        case .noScooterLog:
            return "No scooter log found. Pick c8-scooter-packets.csv (CorckieApp 0.4) or an nRF Connect log export."
        case .needsDate(let name):
            return "\(name) has times of day only and no Sensor Logger file or file date to tell which day it was."
        }
    }
}

public enum RideLogImport {
    public enum Kind: Equatable, Sendable {
        case c8Packets, c8Location, c8Barometer, nrf, sensorLoggerLocation, sensorLoggerBarometer, unknown
    }

    public static func kind(of text: String) -> Kind {
        guard let header = LogReader.lines(text).first else { return .unknown }
        let h = header.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("time,step,app_state,bytes") { return .c8Packets }
        if h.hasPrefix("time,lat,lon,speed_mps") { return .c8Location }
        if h.hasPrefix("time,relative_altitude_m") { return .c8Barometer }
        switch LogFormat.detect(header: h) {
        case .nrfConnect?: return .nrf
        case .sensorLoggerLocation?: return .sensorLoggerLocation
        case .sensorLoggerBarometer?: return .sensorLoggerBarometer
        default: return .unknown
        }
    }

    /// One log per scooter file; phone files go to the log they overlap in time. `utcOffsetMin` gives the phone's UTC offset at an epoch second.
    public static func build(files: [ImportFileText], utcOffsetMin offsetAt: (Double) -> Int) throws -> [ImportedRideLog] {
        let typed = files.map { (file: $0, kind: kind(of: $0.text)) }
        let scooterFiles = typed.filter { $0.kind == .c8Packets || $0.kind == .nrf }
        guard !scooterFiles.isEmpty else { throw RideLogImportError.noScooterLog }
        let phoneFiles = typed.filter { [.c8Location, .c8Barometer, .sensorLoggerLocation, .sensorLoggerBarometer].contains($0.kind) }
        var used = Set<String>()
        var logs: [ImportedRideLog] = []
        for s in scooterFiles {
            let log = try LogReader.scooterLog(s.file.text)
            guard let lastT = log.events.last?.t, !log.events.isEmpty else { continue }
            var scooter = log.events
            var phone: [TimedPhoneEvent] = []
            var names = [s.file.name]
            var notes: [String] = []
            let start: Double
            let offset: Int
            if s.kind == .c8Packets {
                guard let first = LogReader.lines(s.file.text).dropFirst().first, let e = LogReader.isoSeconds(LogReader.csvFields(first)[0]) else { continue }
                start = e
                offset = offsetAt(e)
                for p in phoneFiles where p.kind == .c8Location || p.kind == .c8Barometer {
                    let items = p.kind == .c8Location ? c8Location(p.file.text) : c8Barometer(p.file.text)
                    guard overlaps(items.map(\.t), start, start + lastT) else { continue }
                    phone += items.map { TimedPhoneEvent(t: $0.t, event: $0.event) }
                    names.append(p.file.name)
                    used.insert(p.file.name)
                }
            } else {
                guard let tod = log.startTimeOfDayS else { continue }
                // Sensor Logger files of this ride (by clock time), and from them the day
                var slSets: [(file: ImportFileText, kind: Kind, zero: Double)] = []
                for p in phoneFiles where p.kind == .sensorLoggerLocation || p.kind == .sensorLoggerBarometer {
                    guard let zero = LogReader.sensorLoggerEpochZeroS(p.file.text) else { continue }
                    let local = zero + Double(offsetAt(zero) * 60)
                    let dayTod = local.truncatingRemainder(dividingBy: 86_400)
                    var delta = dayTod - tod
                    if delta > 43_200 { delta -= 86_400 }
                    if delta < -43_200 { delta += 86_400 }
                    if delta >= -3_600 && delta <= lastT + 3_600 { slSets.append((p.file, p.kind, zero)) }
                }
                if let anchor = slSets.first {
                    let off = Double(offsetAt(anchor.zero) * 60)
                    var e = ((anchor.zero + off) / 86_400).rounded(.down) * 86_400 + tod - off
                    if e - anchor.zero > 43_200 { e -= 86_400 }
                    if anchor.zero - e > 43_200 { e += 86_400 }
                    start = e
                    offset = offsetAt(e)
                } else {
                    guard let saved = s.file.modified else { throw RideLogImportError.needsDate(s.file.name) }
                    let savedS = saved.timeIntervalSince1970
                    let off = Double(offsetAt(savedS) * 60)
                    var e = ((savedS + off) / 86_400).rounded(.down) * 86_400 + tod - off
                    if e > savedS + 60 { e -= 86_400 }      // saved after the ride, so the ride was not in the future
                    start = e
                    offset = offsetAt(e)
                    notes.append("day taken from the date of \(s.file.name)")
                }
                for p in slSets {
                    if p.kind == .sensorLoggerLocation, let fixes = try? LogReader.sensorLoggerLocation(p.file.text) {
                        phone += fixes.map { f in
                            var f = f
                            f.t = p.zero + f.t
                            return TimedPhoneEvent(t: f.t, event: .fix(f))
                        }
                    } else if let baro = try? LogReader.sensorLoggerBarometer(p.file.text) {
                        phone += baro.map { b in
                            var b = b
                            b.t = p.zero + b.t
                            return TimedPhoneEvent(t: b.t, event: .baro(b))
                        }
                    } else { continue }
                    names.append(p.file.name)
                    used.insert(p.file.name)
                }
            }
            scooter = scooter.map { TimedScooterEvent(t: $0.t + start, event: $0.event) }
            phone.sort { $0.t < $1.t }
            let source = s.kind == .c8Packets ? "c8" : "nRF Connect"
            logs.append(ImportedRideLog(stream: SimStream(scooter: scooter, phone: phone), startEpoch: start, utcOffsetMin: offset,
                                        source: source, fileNames: names, notes: notes))
        }
        for f in phoneFiles where !used.contains(f.file.name) {
            if let i = logs.indices.last { logs[i].notes.append("\(f.file.name) does not match any scooter log (ignored)") }
        }
        for f in typed where f.kind == .unknown {
            if let i = logs.indices.last { logs[i].notes.append("\(f.file.name) not recognised (ignored)") }
        }
        return logs.sorted { $0.startEpoch < $1.startEpoch }
    }

    // MARK: c8 files (every time is epoch seconds)

    private struct Item {
        var t: Double
        var event: PhoneEvent
    }

    private static func c8Location(_ text: String) -> [Item] {
        var out: [Item] = []
        for line in LogReader.lines(text).dropFirst() {
            let c = LogReader.csvFields(line)
            guard c.count >= 7, let t = LogReader.isoSeconds(c[0]), let lat = Double(c[1]), let lon = Double(c[2]) else { continue }
            let fix = PhoneFix(t: t, lat: lat, lon: lon, hAccM: Double(c[4]) ?? -1, speedMps: Double(c[3]) ?? -1,
                               courseDeg: Double(c[6]) ?? -1, altitudeM: Double(c[5]))
            out.append(Item(t: t, event: .fix(fix)))
        }
        return out
    }

    private static func c8Barometer(_ text: String) -> [Item] {
        var out: [Item] = []
        for line in LogReader.lines(text).dropFirst() {
            let c = LogReader.csvFields(line)
            guard c.count >= 3, let t = LogReader.isoSeconds(c[0]), let rel = Double(c[1]) else { continue }
            out.append(Item(t: t, event: .baro(BaroReading(t: t, relativeAltitudeM: rel, pressureKPa: Double(c[2])))))
        }
        return out
    }

    private static func overlaps(_ times: [Double], _ from: Double, _ to: Double) -> Bool {
        guard let lo = times.min(), let hi = times.max() else { return false }
        return hi >= from - 3_600 && lo <= to + 3_600
    }
}
