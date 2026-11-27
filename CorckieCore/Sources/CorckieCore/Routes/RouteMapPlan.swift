import Foundation

/// Hotfix .14 (N12-7, owner 27 Nov; mock reports/mocks/routes_revise.png): how the route card's map is drawn. The fastest way is the
/// main line (the fastest combination when there is one, else the way with the shortest usual time), the other ways are thin and
/// grey with a "+N min" chip, a tapped way lights up instead. No dotted lines. Pure, so it is tested on Linux.
public struct RouteMapPlan: Equatable, Sendable {
    public struct Way: Equatable, Sendable {
        public var points: [GeoPoint]
        public var variantId: String?
        public var name: String
        /// "Fastest · 31 min" on the main line, "+4 min" on the others, nil when there is no time to compare
        public var chip: String?
        /// Where the chip sits (the middle of the way)
        public var chipAt: GeoPoint?
        public var isMain: Bool
    }

    public var ways: [Way]
    /// Direction arrows along the main line: position and bearing (degrees, 0 = north, clockwise)
    public var arrows: [(at: GeoPoint, bearingDeg: Double)]

    public static func == (a: RouteMapPlan, b: RouteMapPlan) -> Bool {
        a.ways == b.ways && a.arrows.count == b.arrows.count
            && zip(a.arrows, b.arrows).allSatisfy { $0.at == $1.at && abs($0.bearingDeg - $1.bearingDeg) < 1e-9 }
    }

    /// `combination`: the fastest combination's path (nil = none yet); `selected`: a way the rider tapped (it becomes the main line)
    public static func make(_ lines: [RouteMapLine], combination: [GeoPoint]?, selected: String? = nil) -> RouteMapPlan {
        let timed = lines.filter { $0.medianS != nil }
        let bestS = timed.compactMap(\.medianS).min()
        let fastestId = timed.min { ($0.medianS ?? .infinity) < ($1.medianS ?? .infinity) }?.variantId
        let useCombination = selected == nil && (combination?.count ?? 0) >= 2
        let mainId: String? = selected ?? (useCombination ? nil : (fastestId ?? lines.first?.variantId))
        var ways: [Way] = []
        for l in lines {
            let main = !useCombination && l.variantId == mainId
            var chip: String?
            if let m = l.medianS, let best = bestS {
                let behind = Int(((m - best) / 60).rounded())
                if main {
                    chip = behind <= 0 ? "Fastest \u{00B7} \(minutes(m))" : "\(l.name) \u{00B7} \(minutes(m))"
                } else if behind > 0 {
                    chip = "+\(behind) min"
                }
            } else if main {
                chip = l.name.isEmpty ? nil : l.name
            }
            ways.append(Way(points: l.points, variantId: l.variantId, name: l.name, chip: chip, chipAt: middle(l.points), isMain: main))
        }
        if useCombination, let c = combination {
            ways.append(Way(points: c, variantId: nil, name: "Fastest combination",
                            chip: bestS.map { _ in "Fastest" } ?? "Fastest", chipAt: middle(c), isMain: true))
        }
        // the main line last, so it is drawn on top
        ways.sort { !$0.isMain && $1.isMain }
        let main = ways.last { $0.isMain }?.points ?? []
        return RouteMapPlan(ways: ways, arrows: arrows(main))
    }

    static func minutes(_ s: Double) -> String { "\(max(1, Int((s / 60).rounded()))) min" }

    static func middle(_ p: [GeoPoint]) -> GeoPoint? { p.isEmpty ? nil : p[p.count / 2] }

    /// Three arrows at a quarter, half and three quarters of the way
    static func arrows(_ p: [GeoPoint]) -> [(at: GeoPoint, bearingDeg: Double)] {
        guard p.count >= 8 else { return [] }
        return [p.count / 4, p.count / 2, p.count * 3 / 4].compactMap { i in
            guard i + 1 < p.count else { return nil }
            let a = p[i], b = p[i + 1]
            let north = b.lat - a.lat
            let east = (b.lon - a.lon) * cos((a.lat + b.lat) / 2 * Double.pi / 180)
            guard north != 0 || east != 0 else { return nil }
            var deg = atan2(east, north) * 180 / Double.pi
            if deg < 0 { deg += 360 }
            return (at: a, bearingDeg: deg)
        }
    }
}
