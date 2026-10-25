import Foundation

/// M5-03: what the full ride detail draws beyond the speed-coloured path: the Hills and Wind map layers, the elevation profile with
/// its climbs, and a thinned series for the speed / battery charts. Pure, so it is tested on Linux.

/// One stored reading of the ride, in the units the screens use.
public struct SeriesPoint: Equatable, Sendable {
    public var t: Double
    public var lat: Double?
    public var lon: Double?
    public var hAccM: Double?
    public var speedKmh: Double?
    public var batteryPct: Int?
    public var altM: Double?
    /// F-18: the scooter's power, for the Replay's Power layer and tile (nil when not read)
    public var powerW: Double?
    /// F-33: the controller temperature the scooter reports (nil when not read)
    public var tempC: Double?

    public init(t: Double, lat: Double? = nil, lon: Double? = nil, hAccM: Double? = nil, speedKmh: Double? = nil,
                batteryPct: Int? = nil, altM: Double? = nil, powerW: Double? = nil, tempC: Double? = nil) {
        self.powerW = powerW
        self.tempC = tempC
        self.t = t
        self.lat = lat
        self.lon = lon
        self.hAccM = hAccM
        self.speedKmh = speedKmh
        self.batteryPct = batteryPct
        self.altM = altM
    }

    var hasFix: Bool { lat != nil && lon != nil && (hAccM ?? 0) <= T.t28GoodFixM }
    var point: GeoPoint? {
        guard let lat, let lon else { return nil }
        return GeoPoint(lat: lat, lon: lon)
    }
}

/// A stretch of the path with one level 0...4 (the layer's colour).
public struct LayerSegment: Equatable, Sendable {
    public var coords: [GeoPoint]
    public var level: Int

    public init(coords: [GeoPoint], level: Int) {
        self.coords = coords
        self.level = level
    }
}

public enum MapLayer: String, CaseIterable, Sendable {
    case speed = "Speed"
    case hills = "Hills"
    case wind = "Wind"
    /// F-33: battery % along the route (derived: drain)
    case battery = "Battery"
    /// F-33: the controller temperature the scooter reports (derived: heating rate)
    case temp = "Temp"

    /// The line under the map
    public var legend: String {
        switch self {
        case .speed: return "Colour = speed (light green slow, red fast)"
        case .hills: return "Colour = slope (blue downhill, grey flat, red uphill)"
        case .wind: return "Colour = wind (blue with you, grey across, red against you)"
        case .battery: return "Colour = battery (green full, grey low)"
        case .temp: return "Colour = controller temperature (blue cool, red hot)"
        }
    }
}

public struct ClimbSpan: Equatable, Sendable {
    public var startDistM: Double
    public var endDistM: Double
    public var gainM: Double
    public var gradePct: Double
    /// Battery points used on the climb (start minus end), nil without readings
    public var usedPct: Int?

    /// "+33 m · 3% battery · 4% grade"
    public var text: String {
        var parts = [String(format: "+%.0f m", gainM)]
        if let usedPct, usedPct > 0 { parts.append("\(usedPct)% battery") }
        parts.append(String(format: "%.0f%% grade", gradePct))
        return parts.joined(separator: " \u{00B7} ")
    }
}

public struct ElevPoint: Equatable, Sendable {
    public var distM: Double
    public var altM: Double
}

public enum RideLayers {
    /// Stretches shorter than this are joined to the next (fix noise)
    public static let minStretchM = 25.0
    /// Hills levels by slope in percent: < -6, < -2, within 2, <= 6, above
    public static let slopeEdges = [-6.0, -2.0, 2.0, 6.0]
    /// Wind levels by headwind in km/h: <= -15, <= -5, within 5, < 15, above
    public static let windEdges = [-15.0, -5.0, 5.0, 15.0]

    static func level(_ v: Double, _ edges: [Double]) -> Int {
        if v < edges[0] { return 0 }
        if v < edges[1] { return 1 }
        if v <= edges[2] { return 2 }
        if v <= edges[3] { return 3 }
        return 4
    }

    // MARK: Altitude

    /// Moving average over +-`radius` readings (the barometer is noisy at 5 s steps)
    static func smoothed(_ values: [Double?], radius: Int = 2) -> [Double?] {
        var out: [Double?] = []
        for i in values.indices {
            let lo = max(0, i - radius), hi = min(values.count - 1, i + radius)
            let near = values[lo...hi].compactMap { $0 }
            out.append(near.isEmpty ? nil : near.reduce(0, +) / Double(near.count))
        }
        return out
    }

    // MARK: Hills

    public static func hills(_ points: [SeriesPoint]) -> [LayerSegment] {
        let alt = smoothed(points.map(\.altM))
        var stretches: [(a: GeoPoint, b: GeoPoint, level: Int)] = []
        var anchor: Int?
        for i in points.indices {
            guard points[i].hasFix, let p = points[i].point, alt[i] != nil else { continue }
            guard let a = anchor, let pa = points[a].point, let altA = alt[a], let altB = alt[i] else { anchor = i; continue }
            if points[i].t - points[a].t > 30 { anchor = i; continue }
            let d = Geo.distanceM(pa, p)
            if d < minStretchM { continue }
            let slope = (altB - altA) / d * 100
            stretches.append((pa, p, level(slope, slopeEdges)))
            anchor = i
        }
        return join(stretches)
    }

    // MARK: Wind

    /// Nil when there is no weather for the ride (pattern W: "No wind data yet").
    public static func wind(_ points: [SeriesPoint], rideStartMs: Int64, rows: [WeatherRow]) -> [LayerSegment]? {
        guard !rows.isEmpty else { return nil }
        var stretches: [(a: GeoPoint, b: GeoPoint, level: Int)] = []
        var anchor: Int?
        var any = false
        for i in points.indices {
            guard points[i].hasFix, let p = points[i].point else { continue }
            guard let a = anchor, let pa = points[a].point else { anchor = i; continue }
            if points[i].t - points[a].t > Double(FactorRules.maxFixGapMs) / 1000 { anchor = i; continue }
            let d = Geo.distanceM(pa, p)
            if d < minStretchM { continue }
            let north = (p.lat - pa.lat) * Geo.mPerDegLat
            let east = (p.lon - pa.lon) * Geo.mPerDegLat * cos((pa.lat + p.lat) / 2 * Double.pi / 180)
            let course = RideWeatherCalc.bearing(east: east, north: north)
            let mid = rideStartMs + Int64(((points[a].t + points[i].t) / 2 * 1000).rounded())
            if let w = RideWeatherCalc.at(rows, atMs: mid), let from = w.windFromDeg {
                let hw = w.windKmh * cos((from - course) * Double.pi / 180)
                stretches.append((pa, p, level(hw, windEdges)))
                any = true
            }
            anchor = i
        }
        return any ? join(stretches) : nil
    }

    /// Neighbouring stretches with the same level become one polyline
    static func join(_ stretches: [(a: GeoPoint, b: GeoPoint, level: Int)]) -> [LayerSegment] {
        var out: [LayerSegment] = []
        for s in stretches {
            if var last = out.last, last.level == s.level, last.coords.last == s.a {
                last.coords.append(s.b)
                out[out.count - 1] = last
            } else {
                out.append(LayerSegment(coords: [s.a, s.b], level: s.level))
            }
        }
        return out
    }

    // MARK: Elevation profile and climbs

    /// Distance along the ride against smoothed altitude, and the climbs (rise of 5 m or more, ended by a drop of 3 m).
    /// F-34: with an energy track, a climb's battery cost comes from the track (power shape scaled to the ride's drop), not from
    /// the climb's own whole-percent readings (B38's voltage-sag guard is then not needed).
    public static func elevation(_ points: [SeriesPoint], energy: EnergyTrack? = nil) -> (profile: [ElevPoint], climbs: [ClimbSpan]) {
        let alt = smoothed(points.map(\.altM), radius: 3)
        var profile: [ElevPoint] = []
        var times: [Double] = []
        var dist = 0.0
        var lastGeo: GeoPoint?
        var lastT: Double?
        for i in points.indices {
            let p = points[i]
            if let g = p.point, p.hasFix {
                if let l = lastGeo { dist += Geo.distanceM(l, g) }
                lastGeo = g
            } else if let lt = lastT, let v = p.speedKmh {
                dist += v / 3.6 * max(0, p.t - lt)
            }
            lastT = p.t
            if let a = alt[i] {
                profile.append(ElevPoint(distM: dist, altM: a))
                times.append(p.t)
            }
        }
        guard profile.count >= 2 else { return (profile, []) }

        let rise = 5.0, drop = 3.0
        var climbs: [ClimbSpan] = []
        var lowIndex = 0
        var startIndex: Int?
        var highIndex = 0
        for i in profile.indices {
            let a = profile[i].altM
            if let s = startIndex {
                if a > profile[highIndex].altM { highIndex = i }
                if profile[highIndex].altM - a >= drop || i == profile.count - 1 {
                    if let c = climb(profile, times, points, from: s, to: highIndex, rise: rise, energy: energy) { climbs.append(c) }
                    startIndex = nil
                    lowIndex = i
                }
            } else {
                if a <= profile[lowIndex].altM { lowIndex = i }
                if a - profile[lowIndex].altM >= drop {
                    startIndex = lowIndex
                    highIndex = i
                }
            }
        }
        return (thinned(profile, to: 240), climbs)
    }

    private static func climb(_ profile: [ElevPoint], _ times: [Double], _ points: [SeriesPoint], from: Int, to: Int, rise: Double,
                              energy: EnergyTrack?) -> ClimbSpan? {
        let gain = profile[to].altM - profile[from].altM
        guard to > from, gain >= rise else { return nil }
        let d = profile[to].distM - profile[from].distM
        let grade = d > 0 ? gain / d * 100 : 0
        let used: Int?
        if let energy, energy.source != .none {
            let fromTrack = energy.usedPct(from: times[from], to: times[to]).map { Int($0.rounded()) }
            used = (fromTrack ?? 0) >= batteryResolutionPct ? fromTrack : nil
        } else {
            used = climbBatteryUsed(points, from: times[from], to: times[to], distM: d, gainM: gain)
        }
        return ClimbSpan(startDistM: profile[from].distM, endDistM: profile[to].distM, gainM: gain, gradePct: grade, usedPct: used)
    }

    /// B38 battery reading resolution: the scooter reports whole percent
    public static let batteryResolutionPct = 1
    /// B38 plausibility: a climb can use at most this much energy per km (about twice a hard ride) plus the lift itself
    public static let climbMaxWhPerKm = 40.0
    public static let climbLiftKg = 150.0
    public static let climbLiftEfficiency = 0.6
    /// Wh per battery point (768 Wh pack / 100)
    public static let whPerBatteryPct = 7.68

    /// B38: battery points used on one climb, from the climb's OWN readings only (`from`...`to` seconds): the median of its first
    /// three readings minus the median of its last three (one sagging reading does not count). nil (hidden) when the climb has
    /// fewer than two readings, when the drop is below the reading resolution, or when it is more than the climb could really use
    /// (`climbMaxWhPerKm` over its distance plus lifting `climbLiftKg` up `gainM`, +10 % margin): that is voltage sag, not energy.
    public static func climbBatteryUsed(_ points: [SeriesPoint], from t0: Double, to t1: Double, distM: Double, gainM: Double) -> Int? {
        guard t1 > t0 else { return nil }
        let readings = points.filter { $0.t >= t0 && $0.t <= t1 }.compactMap(\.batteryPct)
        guard readings.count >= 2 else { return nil }
        func median(_ list: ArraySlice<Int>) -> Int {
            let sorted = list.sorted()
            return sorted[sorted.count / 2]
        }
        let k = max(1, min(3, readings.count / 2))
        let used = median(readings.prefix(k)) - median(readings.suffix(k))
        guard used >= batteryResolutionPct else { return nil }
        let liftWh = climbLiftKg * 9.81 * max(0, gainM) / 3_600 / climbLiftEfficiency
        let ceiling = (max(0, distM) / 1_000 * climbMaxWhPerKm + liftWh) / whPerBatteryPct * 1.1
        guard Double(used) <= max(Double(batteryResolutionPct), ceiling) else { return nil }
        return used
    }

    static func thinned<T>(_ list: [T], to max: Int) -> [T] {
        guard list.count > max, max > 1 else { return list }
        let step = Double(list.count - 1) / Double(max - 1)
        return (0..<max).map { list[Int((Double($0) * step).rounded())] }
    }

    /// For the speed / battery charts: at most `max` readings, always the first and the last.
    public static func chartSeries(_ points: [SeriesPoint], max: Int = 300) -> [SeriesPoint] {
        thinned(points.filter { $0.speedKmh != nil || $0.batteryPct != nil }, to: max)
    }
}
