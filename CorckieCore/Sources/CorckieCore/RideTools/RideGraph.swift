import Foundation

/// Note 13 (owner 24-25 Oct): the ride graph. ONE chart with chips: Speed by default (P-7: the default stays simple, P-6: for every
/// rider); add Battery, Height, Incline %, Acceleration, Battery per km, Power, Temp, Wind; each with its own colour and its own scale.
/// The map and the chart are linked both ways (touch the map → the cursor jumps there; touch the chart → the dot on the map). A
/// stretch (a hill) can be selected on the map or the chart; a scatter of two series over the selection says in plain words how
/// strong the link is. Pinch zooms time (the heights auto-fit to the visible stretch) or, pinched vertically, the height of the
/// highlighted line; a double tap resets. This is the maths; the app draws it. Pure, tested on Linux.

public enum GraphSeries: String, CaseIterable, Sendable {
    case speed, battery, height, incline, accel, batteryPerKm, power, temp, wind

    public var title: String {
        switch self {
        case .speed: return "Speed"
        case .battery: return "Battery"
        case .height: return "Height"
        case .incline: return "Incline"
        case .accel: return "Acceleration"
        case .batteryPerKm: return "Battery per km"
        case .power: return "Power"
        case .temp: return "Temp"
        case .wind: return "Wind"
        }
    }

    public var unit: String {
        switch self {
        case .speed: return "km/h"
        case .battery: return "%"
        case .height: return "m"
        case .incline: return "%"
        case .accel: return "m/s\u{00B2}"
        case .batteryPerKm: return "%/km"
        case .power: return "W"
        case .temp: return "\u{00B0}C"
        case .wind: return "km/h"
        }
    }

    /// Its own colour (light and dark both read it)
    public var hex: String {
        switch self {
        case .speed: return "#F28C1B"
        case .battery: return "#22B24C"
        case .height: return "#8D6E63"
        case .incline: return "#E53935"
        case .accel: return "#8E24AA"
        case .batteryPerKm: return "#00897B"
        case .power: return "#F2C21B"
        case .temp: return "#D81B60"
        case .wind: return "#1E88E5"
        }
    }

    /// "21 km/h", "3.2 %", "−0.4 m/s²"
    public func text(_ v: Double) -> String {
        switch self {
        case .speed, .wind: return "\(Int(v.rounded())) \(unit)"
        case .battery: return "\(Int(v.rounded()))%"
        case .height: return "\(Int(v.rounded())) m"
        case .incline: return String(format: "%.1f %%", v).replacingOccurrences(of: "-", with: "\u{2212}")
        case .accel: return String(format: "%.1f m/s\u{00B2}", v).replacingOccurrences(of: "-", with: "\u{2212}")
        case .batteryPerKm: return String(format: "%.1f %%/km", v)
        case .power: return "\(Int(v.rounded())) W"
        case .temp: return "\(Int(v.rounded())) \u{00B0}C"
        }
    }

    public static let defaultChips: [GraphSeries] = [.speed]
}

/// One series as times (s from the ride start) and values, sorted by time
public struct GraphLine: Equatable, Sendable {
    public var series: GraphSeries
    public var times: [Double]
    public var values: [Double]

    public init(series: GraphSeries, times: [Double], values: [Double]) {
        self.series = series
        self.times = times
        self.values = values
    }

    public var isEmpty: Bool { times.count < 2 }

    /// The value at a time: the nearest reading
    public func value(at t: Double) -> Double? {
        ChartCursor.nearestIndex(times, to: t).map { values[$0] }
    }
}

/// A selected stretch of the ride (a hill, or what the finger marked)
public struct GraphSelection: Equatable, Sendable {
    public var from: Double
    public var to: Double
    /// "Climb 2 · +33 m" for a hill, nil for a marked stretch
    public var name: String?

    public init(from: Double, to: Double, name: String? = nil) {
        self.from = min(from, to)
        self.to = max(from, to)
        self.name = name
    }

    public func contains(_ t: Double) -> Bool { t >= from && t <= to }
}

public enum RideGraph {
    // MARK: Series

    public static func line(_ s: GraphSeries, _ data: RideLayerData) -> GraphLine {
        let pts = data.points
        var times: [Double] = []
        var values: [Double] = []
        func add(_ t: Double, _ v: Double?) {
            guard let v, v.isFinite else { return }
            times.append(t)
            values.append(v)
        }
        switch s {
        case .speed: for p in pts { add(p.t, p.speedKmh) }
        case .battery: for p in pts { add(p.t, p.batteryPct.map(Double.init)) }
        case .height:
            let alt = RideLayers.smoothed(pts.map(\.altM), radius: 3)
            for (i, p) in pts.enumerated() { add(p.t, alt[i]) }
        case .incline:
            let g = incline(pts)
            for (i, p) in pts.enumerated() { add(p.t, g[i]) }
        case .accel:
            let a = acceleration(pts)
            for (i, p) in pts.enumerated() { add(p.t, a[i]) }
        case .batteryPerKm: for p in pts { add(p.t, data.energy.bin(at: p.t)?.pctPerKm) }
        case .power: for p in pts { add(p.t, p.powerW) }
        case .temp: for p in pts { add(p.t, p.tempC) }
        case .wind:
            let w = RideLayers.windStretches(pts, rideStartMs: data.rideStartMs, rows: data.weather) ?? []
            for st in w { add(st.t, st.value) }
        }
        return GraphLine(series: s, times: times, values: values)
    }

    /// The chips this ride has data for (Speed first)
    public static func available(_ data: RideLayerData) -> [GraphSeries] {
        GraphSeries.allCases.filter { !line($0, data).isEmpty }
    }

    /// Incline in % from the smoothed height over at least 20 m of path either side
    static func incline(_ points: [SeriesPoint]) -> [Double?] {
        let alt = RideLayers.smoothed(points.map(\.altM), radius: 3)
        let dist = EnergyTrack.distances(points)
        return points.indices.map { i in
            guard alt[i] != nil else { return nil }
            var lo = i, hi = i
            while lo > 0, dist[i] - dist[lo] < 20 { lo -= 1 }
            while hi < points.count - 1, dist[hi] - dist[i] < 20 { hi += 1 }
            guard let a = alt[lo], let b = alt[hi], dist[hi] - dist[lo] >= 20 else { return nil }
            return (b - a) / (dist[hi] - dist[lo]) * 100
        }
    }

    /// Acceleration (+) and deceleration (−) in m/s², from the speed smoothed over ±2 readings
    static func acceleration(_ points: [SeriesPoint]) -> [Double?] {
        let v = RideLayers.smoothed(points.map(\.speedKmh))
        return points.indices.map { i in
            let lo = max(0, i - 2), hi = min(points.count - 1, i + 2)
            guard hi > lo, let a = v[lo], let b = v[hi] else { return nil }
            let dt = points[hi].t - points[lo].t
            return dt > 0 ? (b - a) / 3.6 / dt : nil
        }
    }

    // MARK: Scales

    /// The height a line gets on the shared chart: its own min…max over the visible time (auto-fit), padded; never flat
    public static func range(_ line: GraphLine, within domain: ClosedRange<Double>) -> ClosedRange<Double> {
        var lo = Double.infinity, hi = -Double.infinity
        for (t, v) in zip(line.times, line.values) where domain.contains(t) {
            lo = min(lo, v)
            hi = max(hi, v)
        }
        if !lo.isFinite { lo = line.values.min() ?? 0; hi = line.values.max() ?? 1 }
        let minSpan = minSpan(line.series)
        if hi - lo < minSpan {
            let mid = (hi + lo) / 2
            lo = mid - minSpan / 2
            hi = mid + minSpan / 2
        }
        let pad = (hi - lo) * 0.06
        return (lo - pad)...(hi + pad)
    }

    static func minSpan(_ s: GraphSeries) -> Double {
        switch s {
        case .speed, .wind: return 5
        case .battery: return 4
        case .height: return 6
        case .incline: return 2
        case .accel: return 0.5
        case .batteryPerKm: return 0.5
        case .power: return 100
        case .temp: return 4
        }
    }

    /// Note 13 scale fix (owner): the pinch changes the VALUE SCALE, not the view. `factor` 1 = auto-fit to the whole ride; above 1
    /// the range narrows around the line's own data (its median), so a line that looks flat on ±30 shows its detail on ±5; below 1 it
    /// widens. The time axis always shows the whole ride.
    /// Hotfix 01 (H1): with a time window (`within`) the auto-fit and the median follow the visible stretch.
    public static func scaledRange(_ line: GraphLine, factor: Double, within window: ClosedRange<Double>? = nil) -> ClosedRange<Double> {
        let whole = (line.times.first ?? 0)...(line.times.last ?? 0)
        let base = range(line, within: window ?? whole)
        let f = clampedScale(factor)
        var inside = line.values
        if let window {
            let v = zip(line.times, line.values).filter { window.contains($0.0) }.map { $0.1 }
            if !v.isEmpty { inside = v }
        }
        guard f != 1, !inside.isEmpty else { return base }
        let sorted = inside.sorted()
        let median = sorted[sorted.count / 2]
        let mid = (base.lowerBound + base.upperBound) / 2
        let centre = mid + (median - mid) * (1 - 1 / max(1, f))
        let half = (base.upperBound - base.lowerBound) / 2 / f
        return (centre - half)...(centre + half)
    }

    // MARK: Time zoom (hotfix 01, H1)

    /// Which way a two-finger pinch works, from the fingers' spread at its start: wider than tall zooms time, taller than wide
    /// stretches the value scale (owner: "adjusting scale and zooming in time should coexist").
    public enum PinchAxis: Equatable, Sendable { case time, value }

    public static func pinchAxis(dx: Double, dy: Double) -> PinchAxis {
        abs(dy) > abs(dx) ? .value : .time
    }

    /// The shortest time window a pinch can show, s
    public static let minWindowS = 30.0

    /// A sideways pinch: `scale` > 1 narrows the window around `anchor` (0 left … 1 right of what was shown when the pinch began),
    /// never under `minWindowS`, never wider than the ride and always inside it
    public static func timeZoomed(_ start: ClosedRange<Double>, full: ClosedRange<Double>, scale: Double, anchor: Double) -> ClosedRange<Double> {
        ChartCursor.zoomed(start, full: full, scale: scale.isFinite ? scale : 1, anchor: anchor, minSpanS: minWindowS)
    }

    /// A drag across the chart while zoomed in: `fraction` of the chart's width (finger right → earlier part of the ride)
    public static func timePanned(_ start: ClosedRange<Double>, full: ClosedRange<Double>, fraction: Double) -> ClosedRange<Double> {
        ChartCursor.panned(start, full: full, byS: -fraction * (start.upperBound - start.lowerBound))
    }

    /// True when the window shows less than the whole ride
    public static func isZoomed(_ window: ClosedRange<Double>, full: ClosedRange<Double>) -> Bool {
        (window.upperBound - window.lowerBound) < (full.upperBound - full.lowerBound) - 0.5
    }

    /// The value scale stays between half and 20 × the auto-fit
    public static func clampedScale(_ s: Double) -> Double { min(20, max(0.5, s.isFinite ? s : 1)) }

    /// A vertical pinch on the highlighted line: `scale` > 1 zooms in around the middle
    public static func yZoomed(_ r: ClosedRange<Double>, scale: Double) -> ClosedRange<Double> {
        let s = min(20, max(0.2, scale))
        let mid = (r.lowerBound + r.upperBound) / 2
        let half = (r.upperBound - r.lowerBound) / 2 / s
        return (mid - half)...(mid + half)
    }

    /// 0…1 on the shared chart
    public static func normalised(_ v: Double, in r: ClosedRange<Double>) -> Double {
        let span = r.upperBound - r.lowerBound
        return span > 0 ? (v - r.lowerBound) / span : 0.5
    }

    /// At most `max` readings inside the visible time (the first and last kept), so a long ride stays light to draw
    public static func visible(_ line: GraphLine, domain: ClosedRange<Double>, max: Int = 400) -> [(t: Double, v: Double)] {
        var inside: [(t: Double, v: Double)] = []
        for (t, v) in zip(line.times, line.values) where t >= domain.lowerBound && t <= domain.upperBound { inside.append((t, v)) }
        return RideLayers.thinned(inside, to: max)
    }

    // MARK: Map ↔ chart

    /// The time of the ride's fix nearest to a touched map point (nil when the touch is more than `withinM` from the route)
    public static func time(near p: GeoPoint, points: [SeriesPoint], withinM: Double = 150) -> Double? {
        var best: (t: Double, d: Double)?
        for s in points where s.hasFix {
            guard let g = s.point else { continue }
            let d = Geo.distanceM(p, g)
            if best == nil || d < best!.d { best = (s.t, d) }
        }
        guard let b = best, b.d <= withinM else { return nil }
        return b.t
    }

    /// Where the rider was at a time: the nearest fix
    public static func position(at t: Double, points: [SeriesPoint]) -> GeoPoint? {
        let fixes = points.filter(\.hasFix)
        guard let i = ChartCursor.nearestIndex(fixes.map(\.t), to: t) else { return nil }
        return fixes[i].point
    }

    /// The route fixes inside a selection (the map highlights them)
    public static func path(_ sel: GraphSelection, points: [SeriesPoint]) -> [GeoPoint] {
        points.filter { $0.hasFix && sel.contains($0.t) }.compactMap(\.point)
    }

    /// The ride's hills as selections ("Climb 1 · +33 m"), from the same climbs as the elevation panel
    public static func hills(_ points: [SeriesPoint], energy: EnergyTrack? = nil) -> [GraphSelection] {
        let climbs = RideLayers.elevation(points, energy: energy).climbs
        guard !climbs.isEmpty else { return [] }
        let dist = EnergyTrack.distances(points)
        func time(atDist d: Double) -> Double? {
            guard let i = dist.firstIndex(where: { $0 >= d }) else { return points.last?.t }
            return points[i].t
        }
        return climbs.enumerated().compactMap { k, c in
            guard let a = time(atDist: c.startDistM), let b = time(atDist: c.endDistM), b > a else { return nil }
            return GraphSelection(from: a, to: b, name: "Climb \(k + 1) \u{00B7} +\(Int(c.gainM.rounded())) m")
        }
    }

    /// The hill a time falls on (a map tap on a hill selects it)
    public static func hill(at t: Double, hills: [GraphSelection]) -> GraphSelection? {
        hills.first { $0.contains(t) }
    }

    // MARK: Scatter

    /// x / y pairs at the same moments over the selection (y read at each x reading)
    public static func pairs(x: GraphLine, y: GraphLine, in sel: GraphSelection?) -> [(x: Double, y: Double)] {
        var out: [(x: Double, y: Double)] = []
        for (t, xv) in zip(x.times, x.values) where sel?.contains(t) ?? true {
            guard let i = ChartCursor.nearestIndex(y.times, to: t), abs(y.times[i] - t) <= 5 else { continue }
            out.append((xv, y.values[i]))
        }
        return out
    }

    /// Pearson's r; nil with fewer than 5 pairs or no spread
    public static func correlation(_ pairs: [(x: Double, y: Double)]) -> Double? {
        guard pairs.count >= 5 else { return nil }
        let n = Double(pairs.count)
        let mx = pairs.reduce(0) { $0 + $1.x } / n, my = pairs.reduce(0) { $0 + $1.y } / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for p in pairs {
            sxy += (p.x - mx) * (p.y - my)
            sxx += (p.x - mx) * (p.x - mx)
            syy += (p.y - my) * (p.y - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// The plain-words line under the scatter: "A strong link: more incline goes with lower speed."
    public static func linkText(_ r: Double?, x: GraphSeries, y: GraphSeries) -> String {
        guard let r else { return "Not enough readings here to say." }
        let a = abs(r)
        let strength = a < 0.2 ? "No real link" : (a < 0.4 ? "A weak link" : (a < 0.7 ? "A clear link" : "A strong link"))
        guard a >= 0.2 else { return "No real link between \(x.title.lowercased()) and \(y.title.lowercased()) here." }
        return "\(strength): more \(x.title.lowercased()) goes with \(r > 0 ? "higher" : "lower") \(y.title.lowercased())."
    }
}
