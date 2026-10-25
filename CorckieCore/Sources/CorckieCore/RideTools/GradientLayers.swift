import Foundation

/// F-04: the Speed / Hills / Wind map layers as a continuous colour ramp (the shade follows the value) instead of 4-5 fixed steps.
/// Pure, so it is tested on Linux; the app draws one short coloured line per stretch and the Replay page uses the same ramps.

/// A colour ramp over a fixed value range: stops are spread evenly from `lo` to `hi`, colours are blended in between.
public struct GradientRamp: Equatable, Sendable {
    public var lo: Double
    public var hi: Double
    public var hex: [String]

    public init(lo: Double, hi: Double, hex: [String]) {
        self.lo = lo
        self.hi = hi
        self.hex = hex
    }

    /// 0...1 position of a value on the ramp (clamped)
    public func position(_ value: Double) -> Double {
        guard hi > lo else { return 0 }
        return min(1, max(0, (value - lo) / (hi - lo)))
    }

    /// The blended colour at a value, components 0...1
    public func rgb(at value: Double) -> (r: Double, g: Double, b: Double) {
        let colours = hex.compactMap { SpeedPalette.rgb($0) }
        guard let first = colours.first else { return (0.5, 0.5, 0.5) }
        guard colours.count > 1 else { return first }
        let scaled = position(value) * Double(colours.count - 1)
        let i = min(colours.count - 2, Int(scaled))
        let f = scaled - Double(i)
        let a = colours[i], b = colours[i + 1]
        return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
    }
}

public enum LayerRamps {
    /// Speed: one ramp 0-50 km/h, green -> yellow -> orange -> red. Colour-blind: cividis (dark blue -> yellow).
    public static func speed(colourBlind: Bool) -> GradientRamp {
        colourBlind
            ? GradientRamp(lo: 0, hi: 50, hex: ["#00204D", "#31446B", "#666970", "#958F78", "#CBBA69", "#FFEA46"])
            : GradientRamp(lo: 0, hi: 50, hex: ["#22B24C", "#F2D21B", "#F28C1B", "#E53935"])
    }

    /// Hills: slope -8 ... +8 %, blue downhill -> grey flat -> orange uphill (blue / orange is safe for colour-blind riders)
    public static func hills(colourBlind: Bool) -> GradientRamp {
        GradientRamp(lo: -8, hi: 8, hex: colourBlind ? ["#0072B2", "#BDBDBD", "#E69F00"] : ["#1E88E5", "#9E9E9E", "#F28C1B"])
    }

    /// Wind: headwind component -20 (tailwind) ... +20 km/h (headwind), blue with you -> grey across -> red / vermillion against you
    public static func wind(colourBlind: Bool) -> GradientRamp {
        GradientRamp(lo: -20, hi: 20, hex: colourBlind ? ["#0072B2", "#BDBDBD", "#D55E00"] : ["#1E88E5", "#9E9E9E", "#E53935"])
    }

    public static func ramp(_ layer: MapLayer, colourBlind: Bool) -> GradientRamp {
        switch layer {
        case .speed: return speed(colourBlind: colourBlind)
        case .hills: return hills(colourBlind: colourBlind)
        case .wind: return wind(colourBlind: colourBlind)
        case .battery: return GradientRamp(lo: 0, hi: 100, hex: colourBlind ? ["#BDBDBD", "#0072B2"] : ["#9E9E9E", "#22B24C"])
        case .temp: return GradientRamp(lo: 20, hi: 80, hex: colourBlind ? ["#0072B2", "#BDBDBD", "#D55E00"] : ["#1E88E5", "#F28C1B", "#E53935"])
        }
    }

    /// The small legend under the gradient: left end, middle, right end
    public static func legend(_ layer: MapLayer) -> (low: String, mid: String, high: String) {
        switch layer {
        case .speed: return ("0", "25", "50 km/h")
        case .hills: return ("\u{2212}8% downhill", "flat", "+8% uphill")
        case .wind: return ("tailwind 20", "across", "headwind 20 km/h")
        case .battery: return ("0%", "50%", "100%")
        case .temp: return ("20 \u{00B0}C", "50 \u{00B0}C", "80 \u{00B0}C")
        }
    }
}

/// One stretch of the path with a continuous value (km/h, slope %, or headwind km/h) at its middle time `t` (seconds).
public struct ValueStretch: Equatable, Sendable {
    public var a: GeoPoint
    public var b: GeoPoint
    public var t: Double
    public var value: Double

    public init(a: GeoPoint, b: GeoPoint, t: Double, value: Double) {
        self.a = a
        self.b = b
        self.t = t
        self.value = value
    }
}

extension RideLayers {
    /// The value averaged over `windowS` seconds around each stretch (the line should not flicker)
    public static func smoothedStretches(_ stretches: [ValueStretch], windowS: Double = 10) -> [ValueStretch] {
        guard stretches.count > 1, windowS > 0 else { return stretches }
        var out = stretches
        var lo = 0
        var hi = 0
        let half = windowS / 2
        for i in stretches.indices {
            let t = stretches[i].t
            while lo < i, stretches[lo].t < t - half { lo += 1 }
            if hi < i { hi = i }
            while hi + 1 < stretches.count, stretches[hi + 1].t <= t + half { hi += 1 }
            var sum = 0.0
            for j in lo...hi { sum += stretches[j].value }
            out[i].value = sum / Double(hi - lo + 1)
        }
        return out
    }

    /// Speed along the path (km/h from the scooter or the GPS), one stretch per `minStretchM` of path
    public static func speedStretches(_ points: [SeriesPoint]) -> [ValueStretch] {
        var out: [ValueStretch] = []
        var anchor: Int?
        var sum = 0.0
        var count = 0
        for i in points.indices {
            guard points[i].hasFix, let p = points[i].point else { continue }
            guard let a = anchor, let pa = points[a].point, points[i].t - points[a].t <= 30 else {
                anchor = i
                sum = points[i].speedKmh ?? 0
                count = points[i].speedKmh == nil ? 0 : 1
                continue
            }
            if let v = points[i].speedKmh { sum += v; count += 1 }
            if Geo.distanceM(pa, p) < minStretchM { continue }
            if count > 0 {
                out.append(ValueStretch(a: pa, b: p, t: (points[a].t + points[i].t) / 2, value: sum / Double(count)))
            }
            anchor = i
            sum = points[i].speedKmh ?? 0
            count = points[i].speedKmh == nil ? 0 : 1
        }
        return out
    }

    /// Slope in percent along the path (positive uphill)
    public static func hillStretches(_ points: [SeriesPoint]) -> [ValueStretch] {
        let alt = smoothed(points.map(\.altM))
        var out: [ValueStretch] = []
        var anchor: Int?
        for i in points.indices {
            guard points[i].hasFix, let p = points[i].point, alt[i] != nil else { continue }
            guard let a = anchor, let pa = points[a].point, let altA = alt[a], let altB = alt[i] else { anchor = i; continue }
            if points[i].t - points[a].t > 30 { anchor = i; continue }
            let d = Geo.distanceM(pa, p)
            if d < minStretchM { continue }
            out.append(ValueStretch(a: pa, b: p, t: (points[a].t + points[i].t) / 2, value: (altB - altA) / d * 100))
            anchor = i
        }
        return out
    }

    /// Headwind component in km/h along the path (positive = against you); nil without weather for the ride
    public static func windStretches(_ points: [SeriesPoint], rideStartMs: Int64, rows: [WeatherRow]) -> [ValueStretch]? {
        guard !rows.isEmpty else { return nil }
        var out: [ValueStretch] = []
        var anchor: Int?
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
                out.append(ValueStretch(a: pa, b: p, t: (points[a].t + points[i].t) / 2, value: hw))
            }
            anchor = i
        }
        return out.isEmpty ? nil : out
    }
}
