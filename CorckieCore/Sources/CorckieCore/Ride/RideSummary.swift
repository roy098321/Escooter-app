import Foundation

// M1-13: the ride summary / ride detail, pure. One layout serves both the summary after a ride and the detail
// opened from the Rides list. The screen reads the ride row, its gaps and its samples, hands them over as plain
// values and draws what comes back. Policy P-3: no records, badges or comparisons; only this ride's own numbers.

/// The ride row's columns the summary shows (times in epoch ms, `RideRecord` in the app).
public struct RideDetailInput: Equatable, Sendable {
    public var startAt: Int64
    public var utcOffsetMin: Int?
    /// ride / shortHop / discarded
    public var kind: String
    /// recording / ended / recovered
    public var status: String
    public var endReason: String?
    public var distanceM: Double?
    public var totalS: Double?
    public var movingS: Double?
    public var avgMovingMps: Double?
    public var topSpeedMps: Double?
    public var stops: Int?
    public var energyWhRaw: Double?
    public var usedPct: Double?
    public var startRestPct: Double?
    public var endRestPct: Double?
    public var odoStartKm: Double?
    public var odoEndKm: Double?
    public var elevGainM: Double?
    public var elevLossM: Double?
    public var tempPeakC: Double?
    public var tempRiseC: Double?
    public var ignoredReadings: Int
    public var hasGps: Bool?
    public var isSimulated: Bool

    public init(startAt: Int64, utcOffsetMin: Int? = nil, kind: String = "ride", status: String = "ended",
                endReason: String? = nil, distanceM: Double? = nil, totalS: Double? = nil, movingS: Double? = nil,
                avgMovingMps: Double? = nil, topSpeedMps: Double? = nil, stops: Int? = nil, energyWhRaw: Double? = nil,
                usedPct: Double? = nil, startRestPct: Double? = nil, endRestPct: Double? = nil,
                odoStartKm: Double? = nil, odoEndKm: Double? = nil, elevGainM: Double? = nil, elevLossM: Double? = nil,
                tempPeakC: Double? = nil, tempRiseC: Double? = nil, ignoredReadings: Int = 0, hasGps: Bool? = nil,
                isSimulated: Bool = false) {
        self.startAt = startAt
        self.utcOffsetMin = utcOffsetMin
        self.kind = kind
        self.status = status
        self.endReason = endReason
        self.distanceM = distanceM
        self.totalS = totalS
        self.movingS = movingS
        self.avgMovingMps = avgMovingMps
        self.topSpeedMps = topSpeedMps
        self.stops = stops
        self.energyWhRaw = energyWhRaw
        self.usedPct = usedPct
        self.startRestPct = startRestPct
        self.endRestPct = endRestPct
        self.odoStartKm = odoStartKm
        self.odoEndKm = odoEndKm
        self.elevGainM = elevGainM
        self.elevLossM = elevLossM
        self.tempPeakC = tempPeakC
        self.tempRiseC = tempRiseC
        self.ignoredReadings = ignoredReadings
        self.hasGps = hasGps
        self.isSimulated = isSimulated
    }
}

/// A `gap` row (ms from the ride start; `endT` nil = still open when the ride ended).
public struct RideGapSpan: Equatable, Sendable {
    /// scooter / gps
    public var kind: String
    public var startT: Int64
    public var endT: Int64?

    public init(kind: String, startT: Int64, endT: Int64?) {
        self.kind = kind
        self.startT = startT
        self.endT = endT
    }
}

/// A stored sample as the summary needs it (ms from the ride start).
public struct RidePoint: Equatable, Sendable {
    public var t: Int64
    public var lat: Double?
    public var lon: Double?
    public var hAccM: Double?
    public var speedKmh: Double?
    public var gpsSpeedKmh: Double?
    public var batteryPct: Int?
    /// scooter / phone / walk
    public var mode: String?

    public init(t: Int64, lat: Double? = nil, lon: Double? = nil, hAccM: Double? = nil, speedKmh: Double? = nil,
                gpsSpeedKmh: Double? = nil, batteryPct: Int? = nil, mode: String? = nil) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.hAccM = hAccM
        self.speedKmh = speedKmh
        self.gpsSpeedKmh = gpsSpeedKmh
        self.batteryPct = batteryPct
        self.mode = mode
    }
}

/// The path of the ride on the map: runs coloured by speed (dashed in phone mode) and walking stretches.
public struct RidePathModel: Equatable, Sendable {
    public struct Bounds: Equatable, Sendable {
        public var minLat: Double
        public var maxLat: Double
        public var minLon: Double
        public var maxLon: Double

        public var centerLat: Double { (minLat + maxLat) / 2 }
        public var centerLon: Double { (minLon + maxLon) / 2 }
        /// Degrees, with room around the path and never tighter than ~200 m
        public var latSpan: Double { max((maxLat - minLat) * 1.4, 0.002) }
        public var lonSpan: Double { max((maxLon - minLon) * 1.4, 0.002) }
    }

    public var segments: [LivePath.Segment]
    /// Walking (pushing) stretches, each a run of coordinates
    public var walks: [[LivePath.Coord]]
    public var bounds: Bounds?

    public var isEmpty: Bool { segments.isEmpty && walks.isEmpty }
}

public enum RidePathBuilder {
    public static func build(_ points: [RidePoint]) -> RidePathModel {
        var path = LivePath()
        var walks: [[LivePath.Coord]] = []
        var walkRun: [LivePath.Coord] = []
        var lastCoord: LivePath.Coord?
        var all: [LivePath.Coord] = []
        for p in points.sorted(by: { $0.t < $1.t }) {
            guard let lat = p.lat, let lon = p.lon else { continue }
            if let h = p.hAccM, h > T.t28GoodFixM { continue }
            let c = LivePath.Coord(lat: lat, lon: lon)
            all.append(c)
            if p.mode == "walk" {
                if walkRun.isEmpty, let l = lastCoord { walkRun.append(l) }
                walkRun.append(c)
            } else {
                if !walkRun.isEmpty {
                    walkRun.append(c)
                    walks.append(walkRun)
                    walkRun = []
                }
                path.add(lat: lat, lon: lon, speedKmh: p.speedKmh ?? p.gpsSpeedKmh ?? 0, dashed: p.mode == "phone")
            }
            lastCoord = c
        }
        if walkRun.count > 1 { walks.append(walkRun) }
        var bounds: RidePathModel.Bounds?
        if let first = all.first {
            var b = RidePathModel.Bounds(minLat: first.lat, maxLat: first.lat, minLon: first.lon, maxLon: first.lon)
            for c in all {
                b.minLat = min(b.minLat, c.lat)
                b.maxLat = max(b.maxLat, c.lat)
                b.minLon = min(b.minLon, c.lon)
                b.maxLon = max(b.maxLon, c.lon)
            }
            bounds = b
        }
        return RidePathModel(segments: path.segments, walks: walks, bounds: bounds)
    }
}

public struct SummaryStat: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

public struct SummaryNote: Equatable, Sendable {
    public enum Kind: String, Sendable { case recovered, gap, heat, ignored, phone, walk, simulated }

    public var kind: Kind
    public var text: String
}

public struct RideSummaryModel: Equatable, Sendable {
    /// "Tue 7 Oct, 18:02"
    public var title: String
    /// "Short hop" / "Simulated" or empty
    public var subtitle: String
    /// Time, Moving time, Distance, Avg. speed, Battery, Battery per km
    public var mainStats: [SummaryStat]
    /// Top speed, Energy, Stops, Elevation, Temperature
    public var scooterStats: [SummaryStat]
    public var notes: [SummaryNote]
    /// S7: the map is replaced by a "No GPS on this ride" card
    public var noGps: Bool
    public var path: RidePathModel
    /// The "more info" lines: odometer, end reason
    public var infoLines: [String]
}

public enum RideSummaryBuilder {
    public static func build(_ input: RideDetailInput, gaps: [RideGapSpan], points: [RidePoint]) -> RideSummaryModel {
        let path = RidePathBuilder.build(points)
        let noGps = input.hasGps == false || (input.hasGps == nil && path.isEmpty)
        let offset = input.utcOffsetMin ?? 0

        var subtitle = ""
        if input.kind == "shortHop" { subtitle = "Short hop" }
        if input.isSimulated { subtitle = subtitle.isEmpty ? "Simulated" : subtitle + " \u{00B7} Simulated" }

        let firstPct = points.sorted { $0.t < $1.t }.compactMap(\.batteryPct).first
        let lastPct = points.sorted { $0.t < $1.t }.compactMap(\.batteryPct).last
        let startPct = input.startRestPct ?? firstPct.map(Double.init)
        let endPct = input.endRestPct ?? lastPct.map(Double.init)

        let main: [SummaryStat] = [
            SummaryStat("Time", input.totalS.map(duration) ?? dash),
            SummaryStat("Moving time", input.movingS.map(duration) ?? dash),
            SummaryStat("Distance", input.distanceM.map(distance) ?? dash),
            SummaryStat("Avg. speed", input.avgMovingMps.map { speed($0 * 3.6) } ?? dash),
            SummaryStat("Battery", batteryText(startPct, endPct)),
            SummaryStat("Battery per km", pctPerKm(input))
        ]

        var scooter: [SummaryStat] = [
            SummaryStat("Top speed", input.topSpeedMps.map { speed($0 * 3.6) } ?? dash),
            SummaryStat("Energy", input.energyWhRaw.map { $0 > 0 ? "~\(Int($0.rounded())) Wh" : dash } ?? dash),
            SummaryStat("Stops", input.stops.map { String($0) } ?? dash)
        ]
        scooter.append(SummaryStat("Elevation", elevation(input)))
        scooter.append(SummaryStat("Temperature", temperature(input)))

        var notes: [SummaryNote] = []
        if input.status == "recovered" || input.endReason == "recovered" {
            notes.append(SummaryNote(kind: .recovered,
                                     text: "Recovered: the app was closed during this ride. Everything up to the last stored reading is kept."))
        }
        let scooterGapS = gapSeconds(gaps, kind: "scooter", totalS: input.totalS)
        if scooterGapS > 0 {
            notes.append(SummaryNote(kind: .phone,
                                     text: "Scooter readings were missing for \(duration(scooterGapS)); the phone kept the path (dashed line). Totals leave that stretch out."))
        }
        let gpsGapS = gapSeconds(gaps, kind: "gps", totalS: input.totalS)
        if gpsGapS > 0 {
            notes.append(SummaryNote(kind: .gap, text: "No GPS for \(duration(gpsGapS)); the path has a break there."))
        }
        if !path.walks.isEmpty {
            notes.append(SummaryNote(kind: .walk, text: "Part of this ride was on foot (pushing); it is marked on the map and not counted in the average speed."))
        }
        if let peak = input.tempPeakC {
            if peak >= T.t47VeryHotC {
                notes.append(SummaryNote(kind: .heat, text: "The scooter got very hot (peak \(Int(peak.rounded())) \u{00B0}C). Let it cool down before the next ride."))
            } else if peak >= T.t47HotC {
                notes.append(SummaryNote(kind: .heat, text: "The scooter got hot (peak \(Int(peak.rounded())) \u{00B0}C)."))
            }
        }
        if input.ignoredReadings > 0 {
            notes.append(SummaryNote(kind: .ignored, text: "Some scooter readings were ignored (they did not look real)."))
        }
        if input.isSimulated {
            notes.append(SummaryNote(kind: .simulated, text: "This ride was simulated. It is not a real ride."))
        }

        var info: [String] = []
        if let a = input.odoStartKm, let b = input.odoEndKm {
            info.append(String(format: "Odometer %.1f km to %.1f km", a, b))
        }
        if let reason = endReasonText(input.endReason) { info.append(reason) }

        return RideSummaryModel(title: title(startAt: input.startAt, utcOffsetMin: offset), subtitle: subtitle,
                                mainStats: main, scooterStats: scooter, notes: notes, noGps: noGps, path: path,
                                infoLines: info)
    }

    // MARK: Formatting

    static let dash = "\u{2013}"

    /// "45 s", "34 min", "1 h 05 min"
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let m = total / 60
        if m < 60 { return "\(m) min" }
        return String(format: "%d h %02d min", m / 60, m % 60)
    }

    /// "12.3 km", "0.85 km" under one km
    public static func distance(_ meters: Double) -> String {
        meters < 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.1f km", meters / 1000)
    }

    public static func speed(_ kmh: Double) -> String { "\(Int(kmh.rounded())) km/h" }

    static func batteryText(_ start: Double?, _ end: Double?) -> String {
        switch (start, end) {
        case let (a?, b?): return "\(Int(a.rounded()))% \u{2192} \(Int(b.rounded()))%"
        case let (a?, nil): return "\(Int(a.rounded()))% \u{2192} \(dash)"
        case let (nil, b?): return "\(dash) \u{2192} \(Int(b.rounded()))%"
        default: return dash
        }
    }

    /// M9: used % per km, "~" before calibration, a dash before one km (T43)
    static func pctPerKm(_ input: RideDetailInput) -> String {
        guard let used = input.usedPct, let d = input.distanceM, d >= T.t43BatteryPerKmAfterM else { return dash }
        return "~" + String(format: "%.1f", used / (d / 1000)) + " %/km"
    }

    static func elevation(_ input: RideDetailInput) -> String {
        guard let up = input.elevGainM, let down = input.elevLossM else { return dash }
        return "~+\(Int(up.rounded())) m / \u{2212}\(Int(down.rounded())) m"
    }

    static func temperature(_ input: RideDetailInput) -> String {
        guard let peak = input.tempPeakC else { return dash }
        var s = "peak \(Int(peak.rounded())) \u{00B0}C"
        if let rise = input.tempRiseC, rise >= 1 { s += " (+\(Int(rise.rounded())))" }
        return s
    }

    /// Seconds of the ride's gaps of one kind; a gap still open at the end runs to the ride's end.
    static func gapSeconds(_ gaps: [RideGapSpan], kind: String, totalS: Double?) -> Double {
        var sum = 0.0
        for g in gaps where g.kind == kind {
            let end = g.endT ?? Int64(((totalS ?? 0) * 1000).rounded())
            if end > g.startT { sum += Double(end - g.startT) / 1000 }
        }
        return sum
    }

    static func endReasonText(_ reason: String?) -> String? {
        switch reason {
        case "disconnected": return "Ended when the scooter went out of range"
        case "held": return "Ended by you (held the stop button)"
        case "standstill": return "Ended after standing still"
        case "scooterOff": return "Ended when the scooter was switched off"
        case "recovered": return "Recovered after the app was closed"
        default: return nil
        }
    }

    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Tue 7 Oct, 18:02" at the ride's own UTC offset
    public static func title(startAt: Int64, utcOffsetMin: Int) -> String {
        let local = startAt / 1000 + Int64(utcOffsetMin) * 60
        let days = RideListLogic.localDay(startAt: startAt, utcOffsetMin: utcOffsetMin)
        let key = RideListLogic.dayKey(days)                        // yyyy-MM-dd
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        let weekday = weekdays[((days + 4) % 7 + 7) % 7]            // 1970-01-01 was a Thursday
        let secOfDay = Int(((local % 86_400) + 86_400) % 86_400)
        let time = String(format: "%02d:%02d", secOfDay / 3600, (secOfDay % 3600) / 60)
        return "\(weekday) \(parts[2]) \(months[parts[1] - 1]), \(time)"
    }
}
