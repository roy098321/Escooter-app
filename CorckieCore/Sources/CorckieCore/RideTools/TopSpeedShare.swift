import Foundation

/// Hotfix .12 (owner 25 Nov): the "At top speed" tile (it replaces Cost): the share of MOVING time spent within 10 % of the ride's
/// own top speed. A 70 km/h ride counts 63-70 km/h. Pure, so it is tested on Linux.
public struct TopSpeedShare: Equatable, Sendable {
    /// 0...100, whole percent
    public var pct: Int
    public var loKmh: Int
    public var topKmh: Int
    public var bandS: Double
    public var movingS: Double

    public static let bandFraction = 0.10
    /// Slower than this = standing (as the stop dots use)
    public static let movingKmh = 2.0
    /// A gap longer than this between readings is not counted (a lost link, not riding)
    public static let maxGapS = 30.0

    /// "18%"
    public var text: String { "\(pct)%" }
    /// "64–71 km/h"
    public var bandText: String { "\(loKmh)\u{2013}\(topKmh) km/h" }

    /// nil without speed readings (a phone-only ride with no speed, or a ride that never moved)
    public static func make(_ points: [SeriesPoint]) -> TopSpeedShare? {
        guard let top = points.compactMap(\.speedKmh).max(), top > movingKmh else { return nil }
        let lo = top * (1 - bandFraction)
        var band = 0.0, moving = 0.0
        for i in points.indices.dropFirst() {
            let dt = points[i].t - points[i - 1].t
            guard dt > 0, dt <= maxGapS, let v = points[i - 1].speedKmh, v > movingKmh else { continue }
            moving += dt
            if v >= lo - 0.0001 { band += dt }
        }
        guard moving > 0 else { return nil }
        return TopSpeedShare(pct: Int((band / moving * 100).rounded()), loKmh: Int(lo.rounded()), topKmh: Int(top.rounded()),
                             bandS: band, movingS: moving)
    }
}

/// Hotfix .12 (owner 25 Nov): what the back of each ride tile says (tap a tile, it turns over in place). Three short lines so the
/// back keeps the tile's size: a plain line, the key words (bold), a small line.
public struct TileBack: Equatable, Sendable {
    public var lead: String
    public var key: String
    public var small: String

    public init(_ lead: String, _ key: String, _ small: String) {
        self.lead = lead
        self.key = key
        self.small = small
    }

    /// `label` = the tile's label; `movingText` "38:02" (Time), `share` (At top speed)
    public static func forTile(_ label: String, movingText: String? = nil, share: TopSpeedShare? = nil) -> TileBack? {
        switch label {
        case "Time": return TileBack("Start to end,", "stops included", movingText.map { "moving \($0)" } ?? "")
        case "Distance": return TileBack("Along the", "GPS path", "scooter speed fills gaps")
        case "Avg speed": return TileBack("Distance \u{00F7}", "moving time", "stops left out")
        case "Battery": return TileBack("Start % \u{2212} end %", "read at rest", "not under load")
        case "Top speed": return TileBack("The highest", "speed reported", "by the scooter or GPS")
        case "Climb": return TileBack("Metres gained", "uphill only", "phone barometer")
        case "At top speed":
            guard let s = share else { return TileBack("Moving time within", "10% of top speed", "no speed readings") }
            return TileBack("Moving time at", s.bandText, "\(clock(s.bandS)) of \(clock(s.movingS))")
        case "km left": return TileBack("Battery left \u{00D7}", "km per %", "learned from your rides")
        default: return nil
        }
    }

    /// 455 s -> "7:35"; 3725 s -> "1:02:05"
    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
