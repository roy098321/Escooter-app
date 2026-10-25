import Foundation

/// F-33 (owner 22 Oct): the ride map's layer row, Speed · Hills · Wind · Battery · Temp. Tapping the active button again switches to
/// its derived ("deeper") view: Speed → Steady, Hills → Grade, Wind → Wind cost, Battery → Drain, Temp → Heating. The legend title
/// and colour bar change with the view. Stops are dots on the Speed views. Pure, so it is tested on Linux.

public struct LayerView: Hashable, Sendable {
    public var layer: MapLayer
    /// true = the derived view
    public var deep: Bool

    public init(_ layer: MapLayer, deep: Bool = false) {
        self.layer = layer
        self.deep = deep
    }

    public static let `default` = LayerView(.speed)

    /// The row button's label (it changes when the derived view is on)
    public var buttonLabel: String {
        switch (layer, deep) {
        case (.speed, false): return "Speed"
        case (.speed, true): return "Steady"
        case (.hills, false): return "Hills"
        case (.hills, true): return "Grade"
        case (.wind, false): return "Wind"
        case (.wind, true): return "Wind cost"
        case (.battery, false): return "Battery"
        case (.battery, true): return "Drain"
        case (.temp, false): return "Temp"
        case (.temp, true): return "Heating"
        }
    }

    /// The legend's title
    public var title: String {
        switch (layer, deep) {
        case (.speed, false): return "Speed"
        case (.speed, true): return "Steadiness"
        case (.hills, false): return "Height"
        case (.hills, true): return "Grade"
        case (.wind, false): return "Wind"
        case (.wind, true): return "Wind cost"
        case (.battery, false): return "Battery"
        case (.battery, true): return "Drain"
        case (.temp, false): return "Controller temp"
        case (.temp, true): return "Heating"
        }
    }

    /// A tap on a row button: the active one flips to / from its derived view, another one opens at its base view
    public func tapped(_ button: MapLayer) -> LayerView {
        button == layer ? LayerView(layer, deep: !deep) : LayerView(button)
    }

    /// Stops are drawn on the Speed views only
    public var showsStops: Bool { layer == .speed }
}

/// The colour bar and its words for one view of one ride
public struct LayerScale: Equatable, Sendable {
    public var title: String
    public var ramp: GradientRamp
    public var low: String
    public var high: String
    /// One plain line under the bar (wind cost total), nil = none
    public var note: String?

    public init(title: String, ramp: GradientRamp, low: String, high: String, note: String? = nil) {
        self.title = title
        self.ramp = ramp
        self.low = low
        self.high = high
        self.note = note
    }
}

/// A dot where the rider stopped; sized by how long
public struct StopDot: Equatable, Sendable {
    public var point: GeoPoint
    public var durationS: Double

    public init(point: GeoPoint, durationS: Double) {
        self.point = point
        self.durationS = durationS
    }

    /// "Stopped 2 min" / "Stopped 40 s"
    public var text: String {
        durationS >= 60 ? "Stopped \(Int((durationS / 60).rounded())) min" : "Stopped \(Int(durationS.rounded())) s"
    }
}

/// Everything the layer row needs, made once per ride
public struct RideLayerData {
    public var points: [SeriesPoint]
    public var energy: EnergyTrack
    public var weather: [WeatherRow]
    public var rideStartMs: Int64

    public init(points: [SeriesPoint], energy: EnergyTrack, weather: [WeatherRow], rideStartMs: Int64) {
        self.points = points
        self.energy = energy
        self.weather = weather
        self.rideStartMs = rideStartMs
    }
}

public enum LayerViews {
    /// A stop: slower than this…
    public static let stopKmh = 2.0
    /// …for at least this long
    public static let minStopS = 20.0
    /// Steadiness: change of speed in km/h per second at the hot end
    public static let steadyHotKmhPerS = 3.0
    /// Aerodynamic and rolling losses are equal at about this speed (a typical rider on a commuter scooter)
    public static let aeroEqualsRollingKmh = 25.0

    // MARK: Stretches

    /// The stretches of one view; empty when the ride has nothing for it (the button is then hidden, Wind says "No wind data yet")
    public static func stretches(_ view: LayerView, _ data: RideLayerData) -> [ValueStretch] {
        let pts = data.points
        switch (view.layer, view.deep) {
        case (.speed, false):
            return RideLayers.smoothedStretches(RideLayers.speedStretches(pts))
        case (.speed, true):
            return RideLayers.smoothedStretches(pathStretches(pts, values: speedChange(pts)))
        case (.hills, false):
            return pathStretches(pts, values: RideLayers.smoothed(pts.map(\.altM)))
        case (.hills, true):
            return RideLayers.smoothedStretches(RideLayers.hillStretches(pts))
        case (.wind, false):
            return RideLayers.windStretches(pts, rideStartMs: data.rideStartMs, rows: data.weather).map { RideLayers.smoothedStretches($0) } ?? []
        case (.wind, true):
            return windCost(data)
        case (.battery, false):
            return pathStretches(pts, values: pts.map { $0.batteryPct.map(Double.init) })
        case (.battery, true):
            return pathStretches(pts, values: pts.map { data.energy.bin(at: $0.t)?.pctPerKm })
        case (.temp, false):
            return pathStretches(pts, values: pts.map(\.tempC))
        case (.temp, true):
            return RideLayers.smoothedStretches(pathStretches(pts, values: heatingRate(pts)), windowS: 30)
        }
    }

    /// The row's buttons: the layers this ride has something for (Speed always; Wind always, it may arrive later)
    public static func available(_ data: RideLayerData) -> [MapLayer] {
        MapLayer.allCases.filter { layer in
            switch layer {
            case .speed, .wind: return true
            case .hills: return data.points.contains { $0.altM != nil }
            case .battery: return data.points.filter { $0.batteryPct != nil }.count >= 2
            case .temp: return data.points.filter { $0.tempC != nil }.count >= 2
            }
        }
    }

    /// Per-reading values averaged over each ~25 m stretch of the path (readings without a value are skipped)
    public static func pathStretches(_ points: [SeriesPoint], values: [Double?]) -> [ValueStretch] {
        guard values.count == points.count else { return [] }
        var out: [ValueStretch] = []
        var anchor: Int?
        var sum = 0.0
        var count = 0
        func reset(_ i: Int) {
            anchor = i
            sum = values[i] ?? 0
            count = values[i] == nil ? 0 : 1
        }
        for i in points.indices {
            guard points[i].hasFix, let p = points[i].point else { continue }
            guard let a = anchor, let pa = points[a].point, points[i].t - points[a].t <= 30 else { reset(i); continue }
            if let v = values[i] { sum += v; count += 1 }
            if Geo.distanceM(pa, p) < RideLayers.minStretchM { continue }
            if count > 0 {
                out.append(ValueStretch(a: pa, b: p, t: (points[a].t + points[i].t) / 2, value: sum / Double(count)))
            }
            reset(i)
        }
        return out
    }

    /// Steadiness, from SPEED only: how fast the speed rose or fell (km/h per second), over ±2 readings
    static func speedChange(_ points: [SeriesPoint]) -> [Double?] {
        let v = RideLayers.smoothed(points.map(\.speedKmh))
        return points.indices.map { i in
            let lo = max(0, i - 2), hi = min(points.count - 1, i + 2)
            guard hi > lo, let a = v[lo], let b = v[hi] else { return nil }
            let dt = points[hi].t - points[lo].t
            return dt > 0 ? abs(b - a) / dt : nil
        }
    }

    /// Heating rate in °C per minute over about a minute of readings (+ heating, − cooling)
    static func heatingRate(_ points: [SeriesPoint]) -> [Double?] {
        let known = points.indices.filter { points[$0].tempC != nil }
        guard known.count >= 2 else { return points.map { _ in nil } }
        var out = [Double?](repeating: nil, count: points.count)
        var lo = 0
        for (k, i) in known.enumerated() {
            let t = points[i].t
            while lo < k, points[known[lo]].t < t - 60 { lo += 1 }
            let j = known[lo]
            let dt = t - points[j].t
            guard dt >= 20, let a = points[j].tempC, let b = points[i].tempC else { continue }
            out[i] = (b - a) / dt * 60
        }
        return out
    }

    /// Wind cost: the battery the wind took (headwind) or saved (tailwind), in % per km, from the energy track's drain and how much
    /// of the effort goes into air drag at that speed. A rough model: the wording says "about".
    static func windCost(_ data: RideLayerData) -> [ValueStretch] {
        guard let wind = RideLayers.windStretches(data.points, rideStartMs: data.rideStartMs, rows: data.weather) else { return [] }
        let speed = RideLayers.speedStretches(data.points)
        var out: [ValueStretch] = []
        var k = 0
        for s in RideLayers.smoothedStretches(wind) {
            guard let drain = data.energy.bin(at: s.t)?.pctPerKm else { continue }
            while k + 1 < speed.count, speed[k + 1].t <= s.t { k += 1 }
            guard !speed.isEmpty else { continue }
            let v = speed[k].value
            guard v >= 5 else { continue }
            out.append(ValueStretch(a: s.a, b: s.b, t: s.t, value: drain * windShare(speedKmh: v, headwindKmh: s.value)))
        }
        return out
    }

    /// The share of this stretch's battery use that the wind added (negative: saved), from air drag on (v + w)² against rolling losses
    public static func windShare(speedKmh v: Double, headwindKmh w: Double) -> Double {
        let air = v + w
        let airSq = air * abs(air)
        let c = aeroEqualsRollingKmh
        let withWind = c * c + max(0, airSq)
        guard withWind > 0 else { return 0 }
        return (airSq - v * v) / withWind
    }

    /// The stops (dots on the Speed views): slower than 2 km/h for 20 s or more, not at the very start or end
    public static func stops(_ points: [SeriesPoint]) -> [StopDot] {
        var out: [StopDot] = []
        var runStart: Int?
        for i in points.indices {
            let slow = (points[i].speedKmh ?? 0) < stopKmh
            if slow {
                if runStart == nil { runStart = i }
                continue
            }
            if let s = runStart {
                let duration = points[i].t - points[s].t
                if s > 0, duration >= minStopS, let p = (points[s...i].first { $0.hasFix })?.point {
                    out.append(StopDot(point: p, durationS: duration))
                }
            }
            runStart = nil
        }
        return out
    }

    // MARK: Scale

    public static func scale(_ view: LayerView, stretches: [ValueStretch], energy: EnergyTrack, colourBlind: Bool) -> LayerScale {
        let lo = stretches.map(\.value).min() ?? 0
        let hi = stretches.map(\.value).max() ?? 0
        func span(_ minSpan: Double) -> (Double, Double) {
            let mid = (lo + hi) / 2
            return hi - lo >= minSpan ? (lo, hi) : (mid - minSpan / 2, mid + minSpan / 2)
        }
        switch (view.layer, view.deep) {
        case (.speed, false), (.hills, true), (.wind, false):
            let ramp = LayerRamps.ramp(view.layer, colourBlind: colourBlind)
            let words = LayerRamps.legend(view.layer)
            return LayerScale(title: view.title, ramp: ramp, low: words.low, high: words.high)
        case (.speed, true):
            let hex = colourBlind ? ["#00204D", "#958F78", "#FFEA46"] : ["#26A69A", "#F2D21B", "#E53935"]
            return LayerScale(title: view.title, ramp: GradientRamp(lo: 0, hi: steadyHotKmhPerS, hex: hex), low: "held", high: "sharp changes")
        case (.hills, false):
            let (a, b) = span(10)
            let hex = colourBlind ? ["#0072B2", "#BDBDBD", "#E69F00"] : ["#2E7D32", "#C9B458", "#8D6E63"]
            return LayerScale(title: view.title, ramp: GradientRamp(lo: a, hi: b, hex: hex),
                              low: "\(Int(a.rounded())) m", high: "\(Int(b.rounded())) m")
        case (.wind, true):
            let hex = colourBlind ? ["#0072B2", "#BDBDBD", "#D55E00"] : ["#1E88E5", "#9E9E9E", "#E53935"]
            return LayerScale(title: view.title, ramp: GradientRamp(lo: -1, hi: 1, hex: hex), low: "saved 1%/km", high: "cost 1%/km",
                              note: windCostNote(stretches))
        case (.battery, false):
            let (a, b) = span(5)
            let hex = colourBlind ? ["#BDBDBD", "#0072B2"] : ["#9E9E9E", "#22B24C"]
            return LayerScale(title: view.title, ramp: GradientRamp(lo: a, hi: b, hex: hex),
                              low: "\(Int(a.rounded()))%", high: "\(Int(b.rounded()))%")
        case (.battery, true):
            let hex = colourBlind ? ["#00204D", "#958F78", "#FFEA46"] : ["#22B24C", "#F2D21B", "#E53935"]
            return LayerScale(title: view.title, ramp: GradientRamp(lo: 0, hi: 3, hex: hex), low: "0", high: "3%/km")
        case (.temp, false):
            let (a, b) = span(10)
            let hex = colourBlind ? ["#0072B2", "#BDBDBD", "#D55E00"] : ["#1E88E5", "#F28C1B", "#E53935"]
            return LayerScale(title: view.title, ramp: GradientRamp(lo: a, hi: b, hex: hex),
                              low: "\(Int(a.rounded())) \u{00B0}C", high: "\(Int(b.rounded())) \u{00B0}C")
        case (.temp, true):
            let hex = colourBlind ? ["#0072B2", "#BDBDBD", "#D55E00"] : ["#1E88E5", "#9E9E9E", "#E53935"]
            return LayerScale(title: view.title, ramp: GradientRamp(lo: -1, hi: 1, hex: hex), low: "cooling", high: "+1 \u{00B0}C/min")
        }
    }

    /// "About +2% battery from the wind" / "About 1% battery saved by the wind" (nil when under half a percent)
    public static func windCostNote(_ stretches: [ValueStretch]) -> String? {
        let total = stretches.reduce(0.0) { $0 + $1.value * Geo.distanceM($1.a, $1.b) / 1_000 }
        guard abs(total) >= 0.5 else { return nil }
        let n = Int(abs(total).rounded())
        return total > 0 ? "About +\(n)% battery from the wind" : "About \(n)% battery saved by the wind"
    }

    /// What the map says when a view has nothing to draw
    public static func emptyText(_ view: LayerView) -> String {
        if view.layer == .wind { return "No wind data yet. It arrives with the weather, a little after the ride." }
        if view.deep { return "Not enough readings for this view." }
        return "No \(view.title.lowercased()) readings on this ride."
    }

    // MARK: Hint

    /// "Tap layer for deeper view" shows the first few times a ride with layers is opened
    public static let hintTimes = 5
    public static let hintText = "Tap layer for deeper view"
    public static func showsHint(timesShown: Int) -> Bool { timesShown < hintTimes }
}
