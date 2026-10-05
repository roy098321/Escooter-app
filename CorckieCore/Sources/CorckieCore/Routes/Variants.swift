import Foundation

/// M2-02: one way of riding a route (CALC_SPEC M12).
public struct VariantInfo: Codable, Equatable, Sendable {
    public var id: String
    public var routeId: String
    public var name: String
    public var nameByHand: Bool
    /// The path every 10 m
    public var path: [GeoPoint]
    public var isReference: Bool

    public init(id: String, routeId: String, name: String, nameByHand: Bool = false, path: [GeoPoint], isReference: Bool = false) {
        self.id = id
        self.routeId = routeId
        self.name = name
        self.nameByHand = nameByHand
        self.path = path
        self.isReference = isReference
    }

    /// "Variant 2": the offline fallback name, the only kind the street namer may replace
    public var hasFallbackName: Bool { !nameByHand && name.hasPrefix("Variant ") }
}

public enum VariantMatcher {
    /// A stretch of the ride that leaves the variant
    public struct OffPath: Equatable, Sendable {
        public var startIndex: Int
        public var endIndex: Int
        public var lengthM: Double
        public var offShare: Double
    }

    /// Points inside the corridor may bridge an off-path section by up to this many points (30 m at 10 m steps):
    /// a zigzag that keeps crossing back never forms a long enough section (M12).
    public static let bridgeGapPoints = 3

    /// For every ride point: more than the corridor (T61, 50 m) from the variant? Points in the place-tolerance zone at
    /// either end are never off (a different parking spot is not a different way).
    static func offFlags(_ path: [GeoPoint], from variant: [GeoPoint], endZoneM: Double) -> [Bool] {
        var flags = [Bool](repeating: false, count: path.count)
        let zonePoints = Int((endZoneM / TripBuilder.pathStepM).rounded(.up))
        for i in 0..<path.count {
            if i < zonePoints || i >= path.count - zonePoints { continue }
            flags[i] = Geo.distanceToPathM(path[i], variant) > T.t61CorridorM
        }
        return flags
    }

    /// Share of the ride's points within the corridor of the variant (T61 asks for >= 80%).
    public static func coverage(_ path: [GeoPoint], on variant: [GeoPoint], routeLengthM: Double) -> Double {
        guard !path.isEmpty else { return 0 }
        let flags = offFlags(path, from: variant, endZoneM: PlaceMatcher.toleranceM(tripLengthM: routeLengthM))
        let off = flags.filter { $0 }.count
        return 1 - Double(off) / Double(path.count)
    }

    /// Continuous off-path sections that count (T62): >= 5% of the route and >= 100 m long, >= 80% of their points off.
    public static func offPathSections(_ path: [GeoPoint], from variant: [GeoPoint], routeLengthM: Double) -> [OffPath] {
        let flags = offFlags(path, from: variant, endZoneM: PlaceMatcher.toleranceM(tripLengthM: routeLengthM))
        return sections(flags: flags, routeLengthM: routeLengthM)
    }

    static func sections(flags: [Bool], routeLengthM: Double) -> [OffPath] {
        let minLengthM = max(T.t62OffPathMinM, T.t62OffPathShare * routeLengthM)
        var sections: [OffPath] = []
        var i = 0
        while i < flags.count {
            if !flags[i] {
                i += 1
                continue
            }
            var end = i
            var j = i + 1
            var gap = 0
            while j < flags.count {
                if flags[j] {
                    end = j
                    gap = 0
                } else {
                    gap += 1
                    if gap > bridgeGapPoints { break }
                }
                j += 1
            }
            let count = end - i + 1
            let off = flags[i...end].filter { $0 }.count
            let share = Double(off) / Double(count)
            let length = Double(count) * TripBuilder.pathStepM
            if length >= minLengthM && share >= T.t61CorridorShare {
                sections.append(OffPath(startIndex: i, endIndex: end, lengthM: length, offShare: share))
            }
            i = end + 1
        }
        return sections
    }

    public enum Decision: Equatable, Sendable {
        case same(variantId: String)
        case new
    }

    /// M12: the ride is on an existing variant when that variant leaves no qualifying off-path section (the one with the
    /// best coverage wins); when every variant does, it is a new variant. A noisy ride with no long off-path stretch
    /// stays on its best variant (it never creates one).
    public static func classify(_ path: [GeoPoint], variants: [VariantInfo], routeLengthM: Double) -> Decision {
        var best: (id: String, coverage: Double)?
        let zone = PlaceMatcher.toleranceM(tripLengthM: routeLengthM)
        for v in variants {
            let flags = offFlags(path, from: v.path, endZoneM: zone)
            if !sections(flags: flags, routeLengthM: routeLengthM).isEmpty { continue }
            let c = path.isEmpty ? 0 : 1 - Double(flags.filter { $0 }.count) / Double(path.count)
            if best == nil || c > best!.coverage { best = (v.id, c) }
        }
        if let best { return .same(variantId: best.id) }
        return .new
    }

    /// The part of `path` that is not on `reference` (what makes a variant different); the whole path when it has none.
    public static func distinguishingPoints(of path: [GeoPoint], against reference: [GeoPoint], routeLengthM: Double) -> [GeoPoint] {
        let sections = offPathSections(path, from: reference, routeLengthM: routeLengthM)
        guard !sections.isEmpty else { return path }
        var out: [GeoPoint] = []
        for s in sections { out += path[s.startIndex...s.endIndex] }
        return out
    }

    /// Index of the path that is closest to all the others (smallest mean distance): the medoid (M12 Reference).
    public static func medoidIndex(of paths: [[GeoPoint]]) -> Int? {
        guard paths.count >= 2 else { return paths.isEmpty ? nil : 0 }
        var bestIndex = 0
        var bestCost = Double.infinity
        for (i, a) in paths.enumerated() {
            var cost = 0.0
            for (j, b) in paths.enumerated() where j != i {
                // sample every 3rd point: a medoid does not need every metre
                var sum = 0.0
                var n = 0
                var k = 0
                while k < a.count {
                    sum += Geo.distanceToPathM(a[k], b)
                    n += 1
                    k += 3
                }
                cost += n > 0 ? sum / Double(n) : 0
            }
            if cost < bestCost {
                bestCost = cost
                bestIndex = i
            }
        }
        return bestIndex
    }
}

/// M12 "Naming": the longest street along the distinguishing part; the phone looks up a few points (App layer),
/// this picks the winner so the rule is tested without a geocoder.
public enum StreetNaming {
    /// `streets` = the street at each sampled point in path order (nil = nothing found). The street seen at the most points wins;
    /// a tie goes to the one that appears first.
    public static func longest(_ streets: [String?]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in streets {
            guard let s, !s.isEmpty else { continue }
            if counts[s] == nil { order.append(s) }
            counts[s, default: 0] += 1
        }
        var best: String?
        for s in order where best == nil || counts[s]! > counts[best!]! { best = s }
        return best
    }

    /// "via Ibn Gabirol"
    public static func variantName(street: String?, fallbackIndex: Int) -> String {
        if let street { return "via " + street }
        return "Variant \(fallbackIndex)"
    }

    /// Up to `max` points spread evenly along a path, for the geocoder (coordinates rounded to ~100 m, P-2).
    public static func samplePoints(_ path: [GeoPoint], max maxPoints: Int = 5) -> [GeoPoint] {
        guard maxPoints > 0, !path.isEmpty else { return [] }
        if path.count <= maxPoints { return path.map(rounded) }
        var out: [GeoPoint] = []
        for k in 0..<maxPoints {
            let i = (path.count - 1) * (2 * k + 1) / (2 * maxPoints)
            out.append(rounded(path[i]))
        }
        return out
    }

    public static func rounded(_ p: GeoPoint) -> GeoPoint {
        GeoPoint(lat: (p.lat * 1000).rounded() / 1000, lon: (p.lon * 1000).rounded() / 1000)
    }

    /// Cache key for one rounded point
    public static func cacheKey(_ p: GeoPoint) -> String {
        let r = rounded(p)
        return String(format: "geo.%.3f.%.3f", r.lat, r.lon)
    }
}
