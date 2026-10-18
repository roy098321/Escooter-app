import Foundation

/// B22 / F-10: where the live map's camera should glide to between two 1 Hz fixes. The view animates the camera linearly over
/// `durationS` to `center` (the position predicted for the next fix from speed and course, never more than `maxAheadS` ahead), turned to
/// `headingDeg` (the course while moving above `minHeadingKmh`, held while slower or stopped so the map does not spin).
public struct LiveCameraTrack: Equatable, Sendable {
    public struct Update: Equatable, Sendable {
        public var centerLat: Double
        public var centerLon: Double
        /// nil until a direction of travel is known (north-up until then)
        public var headingDeg: Double?
        /// how long the linear glide takes (the fix interval, 0.3 ... 1.5 s)
        public var durationS: Double

        public init(centerLat: Double, centerLon: Double, headingDeg: Double?, durationS: Double) {
            self.centerLat = centerLat
            self.centerLon = centerLon
            self.headingDeg = headingDeg
            self.durationS = durationS
        }
    }

    /// the prediction never runs further ahead than this (seconds)
    public static let maxAheadS = 1.5
    /// below this speed the heading is held, not updated (GPS course is noise)
    public static let minHeadingKmh = 5.0
    /// share of a heading change taken at each fix (1 = jump, lower = smoother turns)
    static let turnBlend = 0.7

    private var lastLat: Double?
    private var lastLon: Double?
    private var lastAtS: Double?
    public private(set) var headingDeg: Double?

    public init() {}

    public mutating func reset() { self = LiveCameraTrack() }

    /// A new fix at `atS` (seconds). `speedKmh` is the speed on the tile (scooter or GPS); 0 / nil falls back to the distance moved.
    public mutating func fix(lat: Double, lon: Double, atS: Double, speedKmh: Double?) -> Update {
        var dt = 1.0
        var distM = 0.0
        var bearing: Double?
        if let pLat = lastLat, let pLon = lastLon, let pAt = lastAtS {
            dt = min(max(atS - pAt, 0.3), Self.maxAheadS)
            let dN = (lat - pLat) * 111_320.0
            let dE = (lon - pLon) * 111_320.0 * cos(lat * .pi / 180)
            distM = (dN * dN + dE * dE).squareRoot()
            if distM > 0 { bearing = Self.normalised(atan2(dE, dN) * 180 / .pi) }
        }
        lastLat = lat
        lastLon = lon
        lastAtS = atS
        let given = speedKmh ?? 0
        let kmh = given > 0 ? given : distM / dt * 3.6
        let moving = kmh >= Self.minHeadingKmh
        if moving, let b = bearing, distM >= 1.0 {
            if let h = headingDeg {
                let diff = (b - h + 540).truncatingRemainder(dividingBy: 360) - 180
                headingDeg = Self.normalised(h + Self.turnBlend * diff)
            } else {
                headingDeg = b
            }
        }
        var cLat = lat
        var cLon = lon
        if moving, let h = headingDeg {
            let ahead = kmh / 3.6 * dt
            cLat += ahead * cos(h * .pi / 180) / 111_320.0
            cLon += ahead * sin(h * .pi / 180) / (111_320.0 * cos(lat * .pi / 180))
        }
        return Update(centerLat: cLat, centerLon: cLon, headingDeg: headingDeg, durationS: dt)
    }

    /// Camera distance (m): closer when slow, further out when fast so more of the road ahead shows; in steps of 50 m so it rarely changes.
    public static func cameraDistanceM(speedKmh: Double) -> Double {
        let raw = 450 + 16 * max(0, speedKmh)
        return min(950, max(450, (raw / 50).rounded() * 50))
    }

    /// The heading to give the camera so it turns the short way: the equivalent of `target` (mod 360) nearest to `previous`, which may
    /// run past 360 or below 0 (359 -> 1 becomes 359 -> 361, not a 358 degree spin back).
    public static func shortestHeading(from previous: Double?, to target: Double) -> Double {
        guard let p = previous else { return target }
        var diff = (target - p).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return p + diff
    }

    /// F-10 fix: where the rider's dot sits on the visible map: `clearance` above the top of the tiles (never above `minY`).
    public static func dotY(tilesTop: Double, clearance: Double, minY: Double) -> Double {
        max(minY, tilesTop - clearance)
    }

    static func normalised(_ deg: Double) -> Double {
        let r = deg.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}
