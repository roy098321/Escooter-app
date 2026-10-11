import Foundation

/// M5-04: Ride Replay data. A ride becomes a 1 Hz timeline (smooth at any speed up to 50x), a map frame in web-mercator units
/// and the list of map tiles along the route. The HTML itself is in `ReplayTemplate` / `ReplayHTML`. Pure, tested on Linux.

/// One stored reading, seconds from the ride start.
public struct ReplayRow: Equatable, Sendable {
    public var t: Double
    public var lat: Double?
    public var lon: Double?
    public var hAccM: Double?
    public var speedKmh: Double?
    public var gpsKmh: Double?
    public var altM: Double?
    public var powerW: Double?
    public var batteryPct: Double?
    public var tempC: Double?

    public init(t: Double, lat: Double? = nil, lon: Double? = nil, hAccM: Double? = nil, speedKmh: Double? = nil, gpsKmh: Double? = nil,
                altM: Double? = nil, powerW: Double? = nil, batteryPct: Double? = nil, tempC: Double? = nil) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.hAccM = hAccM
        self.speedKmh = speedKmh
        self.gpsKmh = gpsKmh
        self.altM = altM
        self.powerW = powerW
        self.batteryPct = batteryPct
        self.tempC = tempC
    }
}

/// The ride's own totals for the "This ride" tiles (what the app already computed; nil shows a dash).
public struct ReplayRideInfo: Equatable, Sendable {
    public var distanceM: Double?
    public var avgMovingMps: Double?
    public var topSpeedMps: Double?
    public var startPct: Double?
    public var endPct: Double?
    public var energyWh: Double?
    public var elevGainM: Double?
    public var elevLossM: Double?
    public var tempPeakC: Double?
    public var stops: Int?

    public init(distanceM: Double? = nil, avgMovingMps: Double? = nil, topSpeedMps: Double? = nil, startPct: Double? = nil, endPct: Double? = nil,
                energyWh: Double? = nil, elevGainM: Double? = nil, elevLossM: Double? = nil, tempPeakC: Double? = nil, stops: Int? = nil) {
        self.distanceM = distanceM
        self.avgMovingMps = avgMovingMps
        self.topSpeedMps = topSpeedMps
        self.startPct = startPct
        self.endPct = endPct
        self.energyWh = energyWh
        self.elevGainM = elevGainM
        self.elevLossM = elevLossM
        self.tempPeakC = tempPeakC
        self.stops = stops
    }
}

/// What the page's script reads (`const D = ...`). Short keys keep the file small.
public struct ReplayData: Codable, Equatable, Sendable {
    public struct Summary: Codable, Equatable, Sendable {
        public var dist: Double?
        public var mins: Int
        public var avg: Double?
        public var top: Double?
        public var bat0: Double?
        public var bat1: Double?
        public var wh: Double?
        public var whkm: Double?
        public var gain: Double?
        public var loss: Double?
        public var tmax: Double?
        public var stops: Int?
        public var start: String
        public var end: String
    }

    public struct MapFrame: Codable, Equatable, Sendable {
        public var w: Int
        public var h: Int
        /// zoom of the tiles, and the mercator pixel of the frame's top-left corner (to place tiles)
        public var z: Int
        public var ox: Double
        public var oy: Double
    }

    public var title: String
    public var date: String
    /// seconds since local midnight at the first point
    public var t0: Int
    public var spd: [Double]
    public var gps: [Double?]
    public var ele: [Double]
    public var pwr: [Double]
    public var bat: [Double]
    public var tmp: [Double?]
    public var x: [Double]
    public var y: [Double]
    /// [first index, last index] of each stop
    public var stops: [[Int]]
    public var s: Summary
    public var map: MapFrame?
}

public struct ReplayTile: Equatable, Hashable, Sendable {
    public var z: Int
    public var x: Int
    public var y: Int
}

public enum ReplayBuilder {
    /// Never ask the tile server for more than this many tiles for one replay
    public static let maxTiles = 160
    /// Gaps in the stored readings longer than this are held, not drawn through
    public static let holdGapS = 30.0

    // MARK: Mercator

    public static func mercator(lat: Double, lon: Double, z: Int) -> (x: Double, y: Double) {
        let n = 256 * pow(2.0, Double(z))
        let x = (lon + 180) / 360 * n
        let rad = lat * Double.pi / 180
        let y = (1 - log(tan(rad) + 1 / cos(rad)) / Double.pi) / 2 * n
        return (x, y)
    }

    // MARK: Timeline

    /// One point per second from the first to the last reading. Numbers are interpolated; across a gap longer than
    /// `holdGapS` the last value is held; the battery is a step.
    static func timeline(_ input: [ReplayRow]) -> [ReplayRow] {
        let rows = input.sorted { $0.t < $1.t }
        guard let first = rows.first, let last = rows.last else { return [] }
        let start = first.t.rounded(.down)
        let count = Int((last.t - start).rounded(.down)) + 1
        var out: [ReplayRow] = []
        out.reserveCapacity(count)
        var j = 0
        for k in 0..<count {
            let t = start + Double(k)
            while j + 1 < rows.count, rows[j + 1].t <= t { j += 1 }
            let a = rows[j]
            let b: ReplayRow? = j + 1 < rows.count ? rows[j + 1] : nil
            var f = 0.0
            var near = false
            if let b, b.t > a.t, b.t - a.t <= holdGapS {
                f = (t - a.t) / (b.t - a.t)
                near = true
            }
            func mix(_ p: Double?, _ q: Double?) -> Double? {
                guard let p else { return nil }
                guard near, let q else { return p }
                return p + (q - p) * f
            }
            var row = ReplayRow(t: t - start)
            row.lat = mix(a.lat, b?.lat)
            row.lon = mix(a.lon, b?.lon)
            row.hAccM = a.hAccM
            row.speedKmh = mix(a.speedKmh, b?.speedKmh)
            row.gpsKmh = mix(a.gpsKmh, b?.gpsKmh)
            row.altM = mix(a.altM, b?.altM)
            row.powerW = mix(a.powerW, b?.powerW)
            row.batteryPct = a.batteryPct
            row.tempC = mix(a.tempC, b?.tempC)
            out.append(row)
        }
        return out
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private static func clock(_ seconds: Int) -> String {
        let s = ((seconds % 86_400) + 86_400) % 86_400
        return String(format: "%02d:%02d", s / 3_600, s % 3_600 / 60)
    }

    // MARK: Build

    /// - Parameters:
    ///   - startAtMs / utcOffsetMin: the ride's start (local clock labels).
    ///   - stops: standstills in seconds from the ride start.
    public static func make(title: String, dateLabel: String, startAtMs: Int64, utcOffsetMin: Int, rows: [ReplayRow],
                            stops: [(startS: Double, endS: Double)], info: ReplayRideInfo) -> ReplayData? {
        let line = timeline(rows)
        guard line.count >= 2 else { return nil }
        let firstT = rows.map(\.t).min() ?? 0
        let n = line.count
        let localStart = Int((startAtMs / 1000)) + utcOffsetMin * 60 + Int(firstT.rounded(.down))

        var spd: [Double] = []
        var gps: [Double?] = []
        var ele: [Double] = []
        var pwr: [Double] = []
        var bat: [Double] = []
        var tmp: [Double?] = []
        var lastBat = line.compactMap(\.batteryPct).first ?? 0
        var lastSpeed = 0.0
        let alt0 = line.compactMap(\.altM).first ?? 0
        var lastAlt = 0.0
        var lastPwr = 0.0
        for p in line {
            lastSpeed = p.speedKmh ?? p.gpsKmh ?? lastSpeed
            spd.append(round1(lastSpeed))
            gps.append(p.gpsKmh.map(round1))
            lastAlt = p.altM.map { $0 - alt0 } ?? lastAlt
            ele.append(round1(lastAlt))
            lastPwr = p.powerW ?? lastPwr
            pwr.append(lastPwr.rounded())
            lastBat = p.batteryPct ?? lastBat
            bat.append(lastBat)
            tmp.append(p.tempC.map(round1))
        }

        // map: only fixes that are good enough, holes filled from the neighbours
        var frame: ReplayData.MapFrame?
        var xs: [Double] = []
        var ys: [Double] = []
        var good: [Int] = []
        for i in line.indices where line[i].lat != nil && line[i].lon != nil && (line[i].hAccM ?? 0) <= T.t28GoodFixM { good.append(i) }
        let goodSet = Set(good)
        if good.count >= 2 {
            var lats: [Double] = []
            var lons: [Double] = []
            var last = good[0]
            for i in line.indices {
                if goodSet.contains(i) { last = i }
                lats.append(line[last].lat ?? 0)
                lons.append(line[last].lon ?? 0)
            }
            if let plan = plan(lats: lats, lons: lons) {
                frame = ReplayData.MapFrame(w: plan.w, h: plan.h, z: plan.z, ox: plan.ox, oy: plan.oy)
                for i in lats.indices {
                    let m = mercator(lat: lats[i], lon: lons[i], z: plan.z)
                    xs.append(round1(m.x - plan.ox))
                    ys.append(round1(m.y - plan.oy))
                }
            }
        }

        var stopSpans: [[Int]] = []
        for s in stops where s.endS - s.startS >= 5 {
            let a = max(0, min(n - 1, Int((s.startS - firstT).rounded())))
            let b = max(0, min(n - 1, Int((s.endS - firstT).rounded())))
            if b > a { stopSpans.append([a, b]) }
        }

        let dist = info.distanceM.map { $0 / 1000 }
        let moving = spd.filter { $0 >= 1 }
        let top = info.topSpeedMps.map { $0 * 3.6 } ?? spd.max()
        let avg = info.avgMovingMps.map { $0 * 3.6 } ?? (moving.isEmpty ? nil : moving.reduce(0, +) / Double(moving.count))
        let whkm: Double? = {
            guard let wh = info.energyWh, let d = dist, d > 0 else { return nil }
            return round1(wh / d)
        }()
        let distRounded: Double? = dist.map { ($0 * 100).rounded() / 100 }
        let avgRounded: Double? = avg.map { round1($0) }
        let topRounded: Double? = top.map { round1($0) }
        let whRounded: Double? = info.energyWh.map { $0.rounded() }
        let gainRounded: Double? = info.elevGainM.map { $0.rounded() }
        let lossRounded: Double? = info.elevLossM.map { $0.rounded() }
        let peak: Double? = info.tempPeakC ?? tmp.compactMap { $0 }.max()
        let mins = Int((Double(n) / 60).rounded())
        let startLabel = clock(localStart)
        let endLabel = clock(localStart + n - 1)
        let summary = ReplayData.Summary(dist: distRounded, mins: mins, avg: avgRounded, top: topRounded, bat0: info.startPct ?? bat.first,
                                         bat1: info.endPct ?? bat.last, wh: whRounded, whkm: whkm, gain: gainRounded, loss: lossRounded,
                                         tmax: peak, stops: info.stops ?? stopSpans.count, start: startLabel, end: endLabel)

        let t0 = ((localStart % 86_400) + 86_400) % 86_400
        return ReplayData(title: title, date: dateLabel, t0: t0, spd: spd, gps: gps, ele: ele,
                          pwr: pwr, bat: bat, tmp: tmp, x: xs, y: ys, stops: stopSpans, s: summary, map: frame)
    }

    // MARK: Map frame and tiles

    struct Plan {
        var z: Int
        var ox: Double
        var oy: Double
        var w: Int
        var h: Int
    }

    static let pad = 90.0

    /// The highest zoom (17 down to 11) whose corridor needs at most `maxTiles` tiles and whose frame stays under 4000 units.
    static func plan(lats: [Double], lons: [Double]) -> Plan? {
        guard !lats.isEmpty, lats.count == lons.count else { return nil }
        var z = 17
        while z >= 11 {
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            for i in lats.indices {
                let m = mercator(lat: lats[i], lon: lons[i], z: z)
                minX = min(minX, m.x); maxX = max(maxX, m.x); minY = min(minY, m.y); maxY = max(maxY, m.y)
            }
            let w = maxX - minX + 2 * pad, h = maxY - minY + 2 * pad
            if w <= 4_000 && h <= 4_000 {
                let plan = Plan(z: z, ox: minX - pad, oy: minY - pad, w: Int(w.rounded()), h: Int(h.rounded()))
                if corridor(lats: lats, lons: lons, z: z).count <= maxTiles || z == 11 { return plan }
            }
            z -= 1
        }
        return nil
    }

    /// The tiles under the route and a little around it (each fix +- 64 units), sorted for a stable file
    static func corridor(lats: [Double], lons: [Double], z: Int) -> [ReplayTile] {
        var set = Set<ReplayTile>()
        let limit = Int(pow(2.0, Double(z)))
        for i in lats.indices {
            let m = mercator(lat: lats[i], lon: lons[i], z: z)
            for dx in [-64.0, 0, 64.0] {
                for dy in [-64.0, 0, 64.0] {
                    let tx = Int(((m.x + dx) / 256).rounded(.down))
                    let ty = Int(((m.y + dy) / 256).rounded(.down))
                    if tx >= 0, ty >= 0, tx < limit, ty < limit { set.insert(ReplayTile(z: z, x: tx, y: ty)) }
                }
            }
        }
        return set.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// The tiles a replay needs (empty without a map)
    public static func tiles(for data: ReplayData) -> [ReplayTile] {
        guard let m = data.map, !data.x.isEmpty else { return [] }
        var set = Set<ReplayTile>()
        let limit = Int(pow(2.0, Double(m.z)))
        for i in data.x.indices {
            let gx = data.x[i] + m.ox, gy = data.y[i] + m.oy
            for dx in [-64.0, 0, 64.0] {
                for dy in [-64.0, 0, 64.0] {
                    let tx = Int(((gx + dx) / 256).rounded(.down))
                    let ty = Int(((gy + dy) / 256).rounded(.down))
                    if tx >= 0, ty >= 0, tx < limit, ty < limit { set.insert(ReplayTile(z: m.z, x: tx, y: ty)) }
                }
            }
        }
        return set.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }
}
