import Foundation

/// M2-01: plain geometry for places, routes and variants (CALC_SPEC M11, M12). Pure, no CoreLocation,
/// so it is tested on Linux. Distances are metres; the maths is accurate to a few cm over city distances.
public struct GeoPoint: Codable, Equatable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public enum Geo {
    public static let earthRadiusM = 6_371_000.0
    /// Metres per degree of latitude
    static let mPerDegLat = Double.pi * earthRadiusM / 180

    /// Great-circle distance (haversine)
    public static func distanceM(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let p1 = a.lat * Double.pi / 180
        let p2 = b.lat * Double.pi / 180
        let dp = p2 - p1
        let dl = (b.lon - a.lon) * Double.pi / 180
        let s1 = sin(dp / 2)
        let s2 = sin(dl / 2)
        let h = s1 * s1 + cos(p1) * cos(p2) * s2 * s2
        return 2 * earthRadiusM * asin(min(1, sqrt(h)))
    }

    public static func pathLengthM(_ points: [GeoPoint]) -> Double {
        var total = 0.0
        if points.count < 2 { return 0 }
        for i in 1..<points.count { total += distanceM(points[i - 1], points[i]) }
        return total
    }

    /// Points every `stepM` metres along the path (first and last point kept), linear between fixes.
    public static func resample(_ points: [GeoPoint], stepM: Double = 10) -> [GeoPoint] {
        guard points.count >= 2, stepM > 0 else { return points }
        var out: [GeoPoint] = [points[0]]
        var carried = 0.0                 // metres walked since the last output point
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            let seg = distanceM(a, b)
            if seg <= 0 { continue }
            var at = stepM - carried      // distance into this segment of the next output point
            while at <= seg {
                let f = at / seg
                out.append(GeoPoint(lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f))
                at += stepM
            }
            carried = seg - (at - stepM)
        }
        if let last = points.last, let lastOut = out.last, distanceM(lastOut, last) > 0.5 {
            out.append(last)
        }
        return out
    }

    /// Shortest distance from a point to a polyline (segments, not just vertices).
    public static func distanceToPathM(_ p: GeoPoint, _ path: [GeoPoint]) -> Double {
        guard let first = path.first else { return Double.infinity }
        if path.count == 1 { return distanceM(p, first) }
        let mLon = mPerDegLat * cos(p.lat * Double.pi / 180)
        var best = Double.infinity
        for i in 1..<path.count {
            let ax = (path[i - 1].lon - p.lon) * mLon
            let ay = (path[i - 1].lat - p.lat) * mPerDegLat
            let bx = (path[i].lon - p.lon) * mLon
            let by = (path[i].lat - p.lat) * mPerDegLat
            let dx = bx - ax
            let dy = by - ay
            let len2 = dx * dx + dy * dy
            var t = 0.0
            if len2 > 0 { t = max(0, min(1, -(ax * dx + ay * dy) / len2)) }
            let cx = ax + t * dx
            let cy = ay + t * dy
            let d = (cx * cx + cy * cy).squareRoot()
            if d < best { best = d }
        }
        return best
    }

    // MARK: Encoded polyline (precision 1e5, ~1 m), the format stored in `variant.polyline`

    public static func encode(_ points: [GeoPoint]) -> String {
        var out = ""
        var prevLat = 0
        var prevLon = 0
        for p in points {
            let lat = Int((p.lat * 1e5).rounded())
            let lon = Int((p.lon * 1e5).rounded())
            out += encodeValue(lat - prevLat)
            out += encodeValue(lon - prevLon)
            prevLat = lat
            prevLon = lon
        }
        return out
    }

    private static func encodeValue(_ v: Int) -> String {
        var value = v < 0 ? ~(v << 1) : (v << 1)
        var scalars: [UInt8] = []
        while value >= 0x20 {
            scalars.append(UInt8((0x20 | (value & 0x1f)) + 63))
            value >>= 5
        }
        scalars.append(UInt8(value + 63))
        return String(decoding: scalars, as: UTF8.self)
    }

    public static func decode(_ text: String) -> [GeoPoint] {
        let bytes = Array(text.utf8)
        var index = 0
        var lat = 0
        var lon = 0
        var out: [GeoPoint] = []
        func next() -> Int? {
            var result = 0
            var shift = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 {
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }
        while let dLat = next(), let dLon = next() {
            lat += dLat
            lon += dLon
            out.append(GeoPoint(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5))
        }
        return out
    }

    /// Median of a list (nil when empty).
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
