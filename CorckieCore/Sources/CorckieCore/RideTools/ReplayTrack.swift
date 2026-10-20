import Foundation

/// F-18 / F-28 (P6-4): the native Ride Replay and the full-screen ride charts. A ride's stored readings become a track the
/// replay plays (position, speed, battery, power, elevation and distance at any second), the coloured path per layer, a chart
/// cursor that snaps to the nearest reading and follows the playback clock, a pinch zoom on the time axis, and the B39 map fit
/// that ignores stray GPS fixes. Pure, so it is tested on Linux; the app only draws it.

/// The Replay's layer chips: what colours the path and what the chart strip shows.
public enum ReplayLayer: String, CaseIterable, Sendable {
    case speed = "Speed"
    case battery = "Battery"
    case power = "Power"
    case elevation = "Elevation"

    public var unit: String {
        switch self {
        case .speed: return "km/h"
        case .battery: return "%"
        case .power: return "W"
        case .elevation: return "m"
        }
    }
}

public struct ReplayTrack: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        /// seconds from the first reading
        public var t: Double
        /// only good fixes; nil = no position at this reading
        public var lat: Double?
        public var lon: Double?
        public var speedKmh: Double?
        /// held from the last reading (a step)
        public var batteryPct: Int?
        public var powerW: Double?
        /// metres above the first altitude reading
        public var altM: Double?
        /// distance along the ride so far
        public var distM: Double

        public init(t: Double, lat: Double? = nil, lon: Double? = nil, speedKmh: Double? = nil, batteryPct: Int? = nil, powerW: Double? = nil,
                    altM: Double? = nil, distM: Double = 0) {
            self.t = t
            self.lat = lat
            self.lon = lon
            self.speedKmh = speedKmh
            self.batteryPct = batteryPct
            self.powerW = powerW
            self.altM = altM
            self.distM = distM
        }
    }

    /// What the tiles and the dot show at one moment of the playback
    public struct State: Equatable, Sendable {
        public var t: Double
        public var lat: Double?
        public var lon: Double?
        public var speedKmh: Double?
        public var batteryPct: Int?
        public var powerW: Double?
        public var altM: Double?
        public var distM: Double
    }

    public let samples: [Sample]
    public let times: [Double]

    public init(samples: [Sample]) {
        self.samples = samples
        self.times = samples.map(\.t)
    }

    public var durationS: Double { samples.last?.t ?? 0 }
    public var isEmpty: Bool { samples.count < 2 }
    public var coordinates: [GeoPoint] {
        samples.compactMap { s in s.lat.flatMap { lat in s.lon.map { GeoPoint(lat: lat, lon: $0) } } }
    }

    /// The stored readings, sorted, as seconds from the first one. Distance as in the elevation profile (GPS between good fixes,
    /// speed × time without one); battery is held between readings.
    public static func build(_ points: [SeriesPoint]) -> ReplayTrack {
        let sorted = points.sorted { $0.t < $1.t }
        guard let t0 = sorted.first?.t else { return ReplayTrack(samples: []) }
        let alt0 = sorted.compactMap(\.altM).first
        var out: [Sample] = []
        out.reserveCapacity(sorted.count)
        var dist = 0.0
        var lastGeo: GeoPoint?
        var lastT: Double?
        var lastBattery: Int?
        for p in sorted {
            var s = Sample(t: p.t - t0, speedKmh: p.speedKmh, powerW: p.powerW)
            if p.hasFix, let g = p.point {
                if let l = lastGeo { dist += Geo.distanceM(l, g) }
                lastGeo = g
                s.lat = g.lat
                s.lon = g.lon
            } else if let lt = lastT, let v = p.speedKmh {
                dist += v / 3.6 * max(0, p.t - lt)
            }
            lastT = p.t
            lastBattery = p.batteryPct ?? lastBattery
            s.batteryPct = lastBattery
            if let a = p.altM, let a0 = alt0 { s.altM = a - a0 }
            s.distM = dist
            out.append(s)
        }
        return ReplayTrack(samples: out)
    }

    /// The replay's 1 Hz timeline (the same data the shared HTML file plays) as a track. Mercator units back to degrees; a layer
    /// that was never read (all zero: no altitude, power or battery readings) is left out; the distance is scaled to the ride's own.
    public static func from(_ data: ReplayData) -> ReplayTrack {
        let n = data.spd.count
        let hasAlt = data.ele.contains { $0 != 0 }
        let hasPower = data.pwr.contains { $0 != 0 }
        let hasBattery = data.bat.contains { $0 != 0 }
        var points: [SeriesPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            var p = SeriesPoint(t: Double(i), speedKmh: data.spd[i])
            if hasBattery, i < data.bat.count { p.batteryPct = Int(data.bat[i].rounded()) }
            if hasAlt, i < data.ele.count { p.altM = data.ele[i] }
            if hasPower, i < data.pwr.count { p.powerW = data.pwr[i] }
            if let m = data.map, i < data.x.count, i < data.y.count {
                let g = ReplayBuilder.degrees(x: data.x[i] + m.ox, y: data.y[i] + m.oy, z: m.z)
                p.lat = g.lat
                p.lon = g.lon
                p.hAccM = 0
            }
            points.append(p)
        }
        let track = build(points)
        guard let km = data.s.dist, km > 0, let last = track.samples.last?.distM, last > 0 else { return track }
        let k = km * 1_000 / last
        return ReplayTrack(samples: track.samples.map { s in
            var c = s
            c.distM = s.distM * k
            return c
        })
    }

    /// The moment `t` (clamped to the ride): numbers blended between the two readings around it, the dot between the two fixes
    /// around it (held at the last fix through a GPS hole), the battery a step.
    public func state(atTime t: Double) -> State? {
        guard !samples.isEmpty else { return nil }
        let time = min(max(0, t), durationS)
        let i = ChartCursor.lastIndex(times, atOrBefore: time) ?? 0
        let a = samples[i]
        let b = i + 1 < samples.count ? samples[i + 1] : a
        let f = b.t > a.t ? (time - a.t) / (b.t - a.t) : 0
        func mix(_ p: Double?, _ q: Double?) -> Double? {
            guard let p else { return nil }
            guard let q else { return p }
            return p + (q - p) * f
        }
        var lat: Double?
        var lon: Double?
        if a.lat != nil, b.lat != nil {
            lat = mix(a.lat, b.lat)
            lon = mix(a.lon, b.lon)
        } else if let k = samples[...i].lastIndex(where: { $0.lat != nil }) {
            lat = samples[k].lat
            lon = samples[k].lon
        } else if let k = samples.firstIndex(where: { $0.lat != nil }) {
            lat = samples[k].lat
            lon = samples[k].lon
        }
        return State(t: time, lat: lat, lon: lon, speedKmh: mix(a.speedKmh, b.speedKmh), batteryPct: a.batteryPct,
                     powerW: mix(a.powerW, b.powerW), altM: mix(a.altM, b.altM), distM: a.distM + (b.distM - a.distM) * f)
    }

    public func value(_ layer: ReplayLayer, _ s: Sample) -> Double? {
        switch layer {
        case .speed: return s.speedKmh
        case .battery: return s.batteryPct.map(Double.init)
        case .power: return s.powerW
        case .elevation: return s.altM
        }
    }

    public func has(_ layer: ReplayLayer) -> Bool { samples.contains { value(layer, $0) != nil } }

    /// The path coloured by one layer: one stretch per `minStretchM` of path between good fixes (never across a hole over 30 s),
    /// valued by the mean of the readings in it.
    public func stretches(_ layer: ReplayLayer, minStretchM: Double = 20) -> [ValueStretch] {
        var out: [ValueStretch] = []
        var anchor: Int?
        var sum = 0.0
        var count = 0
        func reset(_ i: Int) {
            anchor = i
            if let v = value(layer, samples[i]) { sum = v; count = 1 } else { sum = 0; count = 0 }
        }
        for i in samples.indices {
            guard let lat = samples[i].lat, let lon = samples[i].lon else { continue }
            guard let a = anchor, let alat = samples[a].lat, let alon = samples[a].lon, samples[i].t - samples[a].t <= 30 else {
                reset(i)
                continue
            }
            if let v = value(layer, samples[i]) { sum += v; count += 1 }
            let pa = GeoPoint(lat: alat, lon: alon), p = GeoPoint(lat: lat, lon: lon)
            if Geo.distanceM(pa, p) < minStretchM { continue }
            if count > 0 { out.append(ValueStretch(a: pa, b: p, t: (samples[a].t + samples[i].t) / 2, value: sum / Double(count))) }
            reset(i)
        }
        return out
    }

    /// The coloured stretches merged into runs of one colour step (`steps` per ramp), so the map draws tens of lines instead of
    /// hundreds while the dot moves. Runs only join where one stretch ends where the next begins.
    public static func runs(_ stretches: [ValueStretch], ramp: GradientRamp, steps: Int = 16) -> [(coords: [GeoPoint], value: Double)] {
        var out: [(coords: [GeoPoint], value: Double)] = []
        let n = Double(max(1, steps))
        for s in stretches {
            let bin = min(n - 1, (ramp.position(s.value) * n).rounded(.down))
            let value = ramp.lo + (bin + 0.5) / n * (ramp.hi - ramp.lo)
            if let last = out.last, last.value == value, last.coords.last == s.a {
                out[out.count - 1].coords.append(s.b)
            } else {
                out.append((coords: [s.a, s.b], value: value))
            }
        }
        return out
    }

    /// The colour ramp of a layer. Speed is the app's speed ramp; battery runs red (empty) to green (full); power like speed
    /// over 0-1500 W; elevation blue (lowest of this ride) to orange (highest). Colour-blind: cividis / blue-orange.
    public func ramp(_ layer: ReplayLayer, colourBlind: Bool) -> GradientRamp {
        switch layer {
        case .speed:
            return LayerRamps.speed(colourBlind: colourBlind)
        case .battery:
            return GradientRamp(lo: 0, hi: 100, hex: colourBlind ? ["#00204D", "#666970", "#FFEA46"] : ["#E53935", "#F2D21B", "#22B24C"])
        case .power:
            return GradientRamp(lo: 0, hi: 1_500, hex: colourBlind ? ["#00204D", "#31446B", "#958F78", "#FFEA46"] : ["#22B24C", "#F2D21B", "#F28C1B", "#E53935"])
        case .elevation:
            let alts = samples.compactMap(\.altM)
            let lo = alts.min() ?? 0
            let hi = max(lo + 1, alts.max() ?? 1)
            return GradientRamp(lo: lo, hi: hi, hex: colourBlind ? ["#0072B2", "#BDBDBD", "#E69F00"] : ["#1E88E5", "#9E9E9E", "#F28C1B"])
        }
    }
}

/// F-18 / F-28: the shared chart cursor and time-axis zoom of the Replay strip and the full-screen charts.
public enum ChartCursor {
    /// Index of the last time at or before `t` in sorted `times` (nil when `t` is before the first)
    public static func lastIndex(_ times: [Double], atOrBefore t: Double) -> Int? {
        guard let first = times.first, t >= first else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Index of the time nearest to `t` in sorted `times` (the reading the cursor snaps to)
    public static func nearestIndex(_ times: [Double], to t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        guard let i = lastIndex(times, atOrBefore: t) else { return 0 }
        guard i + 1 < times.count else { return i }
        return t - times[i] <= times[i + 1] - t ? i : i + 1
    }

    /// The time under a finger `x` points from the left edge of a plot `width` wide showing `domain` (clamped to it)
    public static func time(atX x: Double, width: Double, domain: ClosedRange<Double>) -> Double {
        guard width > 0 else { return domain.lowerBound }
        let f = min(1, max(0, x / width))
        return domain.lowerBound + f * (domain.upperBound - domain.lowerBound)
    }

    /// Where time `t` sits on that plot (the inverse of `time(atX:)`)
    public static func x(ofTime t: Double, width: Double, domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        return (t - domain.lowerBound) / span * width
    }

    /// Pinch zoom on the time axis: `scale` > 1 zooms in around `anchor` (0 = left edge, 1 = right edge of what is shown); never
    /// tighter than `minSpanS`, never wider than the whole ride, and always inside it.
    public static func zoomed(_ domain: ClosedRange<Double>, full: ClosedRange<Double>, scale: Double, anchor: Double = 0.5,
                              minSpanS: Double = 30) -> ClosedRange<Double> {
        let fullSpan = full.upperBound - full.lowerBound
        guard fullSpan > 0, scale > 0 else { return full }
        let span = domain.upperBound - domain.lowerBound
        let newSpan = min(fullSpan, max(min(minSpanS, fullSpan), span / scale))
        let a = min(1, max(0, anchor))
        let pivot = domain.lowerBound + a * span
        return clamp(lo: pivot - a * newSpan, span: newSpan, full: full)
    }

    /// Move the shown window by `byS` seconds, kept inside the ride
    public static func panned(_ domain: ClosedRange<Double>, full: ClosedRange<Double>, byS: Double) -> ClosedRange<Double> {
        clamp(lo: domain.lowerBound + byS, span: domain.upperBound - domain.lowerBound, full: full)
    }

    static func clamp(lo: Double, span: Double, full: ClosedRange<Double>) -> ClosedRange<Double> {
        let s = min(span, full.upperBound - full.lowerBound)
        let start = min(max(full.lowerBound, lo), full.upperBound - s)
        return start...(start + s)
    }

    /// The readings worth drawing for a shown window: those inside it plus one on each side (so lines reach the edges), thinned to at
    /// most `max` (always keeping the first and the last)
    public static func visible(_ times: [Double], domain: ClosedRange<Double>, max: Int = 600) -> [Int] {
        guard !times.isEmpty else { return [] }
        let a = Swift.max(0, (lastIndex(times, atOrBefore: domain.lowerBound) ?? 0))
        let b = Swift.min(times.count - 1, (lastIndex(times, atOrBefore: domain.upperBound) ?? 0) + 1)
        guard b >= a else { return [] }
        let all = Array(a...b)
        guard all.count > max, max > 1 else { return all }
        let step = Double(all.count - 1) / Double(max - 1)
        return (0..<max).map { all[Int((Double($0) * step).rounded())] }
    }

    /// B37: the battery chart's axis: whole tens around the readings (at least 10 points tall) with three ticks only, so the labels
    /// never crowd a short chart
    public static func batteryAxis(min lo: Double, max hi: Double) -> (domain: ClosedRange<Double>, ticks: [Double]) {
        var a = Swift.max(0, (Swift.min(lo, hi) / 10).rounded(.down) * 10)
        var b = Swift.min(100, (Swift.max(lo, hi) / 10).rounded(.up) * 10)
        if b - a < 10 {
            if a + 10 <= 100 { b = a + 10 } else { a = b - 10 }
        }
        return (a...b, [a, (a + b) / 2, b])
    }

    /// "12:34" (minutes:seconds) or "1:02:03" for a time from the ride start
    public static func clock(_ seconds: Double) -> String {
        let s = Swift.max(0, Int(seconds.rounded(.down)))
        if s >= 3_600 { return String(format: "%d:%02d:%02d", s / 3_600, s % 3_600 / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// B39: the ride map is framed on the path itself, not on a stray fix kilometres away.
public struct MapFitRegion: Equatable, Sendable {
    public var centerLat: Double
    public var centerLon: Double
    public var latSpan: Double
    public var lonSpan: Double
}

public enum MapFit {
    /// The fixes that belong to the path: within `factor` × the 90th-percentile distance from the median point (and never closer than
    /// `keepWithinM`), so one wild fix far away is dropped while a long straight ride keeps both its ends.
    public static func inliers(_ points: [GeoPoint], keepWithinM: Double = 400, factor: Double = 4) -> [GeoPoint] {
        guard points.count >= 5 else { return points }
        let lats = points.map(\.lat).sorted(), lons = points.map(\.lon).sorted()
        let mid = GeoPoint(lat: lats[lats.count / 2], lon: lons[lons.count / 2])
        let d = points.map { Geo.distanceM(mid, $0) }
        let sorted = d.sorted()
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.9))]
        let limit = max(keepWithinM, factor * p90)
        return zip(points, d).filter { $0.1 <= limit }.map(\.0)
    }

    /// The region that shows the whole path with `padding` (share of the path's size on each side), at least `minSpanDeg` wide.
    /// `topCover`: the share of the map hidden under the floating top bar; the region grows by it and moves north so the path sits
    /// in the visible part.
    public static func region(_ points: [GeoPoint], padding: Double = 0.15, minSpanDeg: Double = 0.003, topCover: Double = 0) -> MapFitRegion? {
        let kept = inliers(points)
        guard let first = kept.first else { return nil }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for p in kept {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        let latSpan = max((maxLat - minLat) * (1 + 2 * padding), minSpanDeg)
        let lonSpan = max((maxLon - minLon) * (1 + 2 * padding), minSpanDeg)
        let cover = min(0.6, max(0, topCover))
        let total = latSpan / (1 - cover)
        return MapFitRegion(centerLat: (minLat + maxLat) / 2 + cover * total / 2, centerLon: (minLon + maxLon) / 2,
                            latSpan: total, lonSpan: lonSpan)
    }
}
