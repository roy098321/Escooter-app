import Foundation

/// Hotfix .12 (owner 25 Nov): tapping "Climb 1" under Elevation takes the map to that climb. Pure, so it is tested on Linux.
/// The climb's stretch is found with the same distance-along-the-ride the elevation profile uses, so the map, the chart band and
/// the row all point at the same place.
public struct ClimbFocus: Equatable, Sendable {
    /// 1-based, as the row shows it
    public var number: Int
    public var coords: [GeoPoint]
    public var startDistM: Double
    public var endDistM: Double
    /// "Climb 1"
    public var title: String { "Climb \(number)" }
    /// "km 0.6–1.4 · +9 m · 3% battery"
    public var line: String

    public init(number: Int, coords: [GeoPoint], startDistM: Double, endDistM: Double, line: String) {
        self.number = number
        self.coords = coords
        self.startDistM = startDistM
        self.endDistM = endDistM
        self.line = line
    }

    /// The climb's path and words; nil when the stretch has fewer than 2 GPS fixes (nothing to show on the map)
    public static func make(_ points: [SeriesPoint], climbs: [ClimbSpan], index: Int) -> ClimbFocus? {
        guard climbs.indices.contains(index) else { return nil }
        let c = climbs[index]
        let dist = RideLayers.profileDistances(points)
        var coords: [GeoPoint] = []
        for i in points.indices where dist[i] >= c.startDistM - 1 && dist[i] <= c.endDistM + 1 {
            if points[i].hasFix, let g = points[i].point { coords.append(g) }
        }
        guard coords.count >= 2 else { return nil }
        var parts = [String(format: "km %.1f\u{2013}%.1f", c.startDistM / 1000, c.endDistM / 1000), String(format: "+%.0f m", c.gainM)]
        if let used = c.usedPct, used > 0 { parts.append("\(used)% battery") }
        return ClimbFocus(number: index + 1, coords: coords, startDistM: c.startDistM, endDistM: c.endDistM,
                          line: parts.joined(separator: " \u{00B7} "))
    }

    /// The next / previous climb, wrapping round (the card's ‹ › buttons)
    public static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}

extension RideLayers {
    /// Distance along the ride at each reading, exactly as `elevation` measures its profile (GPS between fixes, else speed × time)
    public static func profileDistances(_ points: [SeriesPoint]) -> [Double] {
        var out: [Double] = []
        var dist = 0.0
        var lastGeo: GeoPoint?
        var lastT: Double?
        for p in points {
            if let g = p.point, p.hasFix {
                if let l = lastGeo { dist += Geo.distanceM(l, g) }
                lastGeo = g
            } else if let lt = lastT, let v = p.speedKmh {
                dist += v / 3.6 * max(0, p.t - lt)
            }
            lastT = p.t
            out.append(dist)
        }
        return out
    }
}
