import Foundation

// M6-01 (Q23, CALC_SPEC M12 "Choice points"): where the ridden paths of one route split and rejoin, the options at each
// place, and what each ride spent on each option. Pure, so the detection is tested on Linux with made-up ride sets.
//
// 1. Every ride is resampled every 10 m with its time (and battery / energy) interpolated, then projected on the reference path.
// 2. A stretch that is more than 30 m from the reference for >= 40 m (outside the place zones at both ends) is a split / rejoin pair.
// 3. Pairs whose split and rejoin are both within 40 m (along the reference) are one choice point; overlapping ones are joined.
// 4. Every ride's path between the split and the rejoin is one option: paths within 30 m of each other (80% of the points
//    both ways) are the same option; the reference's own stretch is always an option.
// 5. Time / used % / energy from split to rejoin of every ride → `ride_option`.

public struct TimedFix: Equatable, Sendable {
    /// Seconds since the ride start
    public var t: Double
    public var lat: Double
    public var lon: Double
    public var hAccM: Double?
    public var batteryPct: Double?
    /// Energy used since the ride start (Wh), when known
    public var energyWh: Double?

    public init(t: Double, lat: Double, lon: Double, hAccM: Double? = nil, batteryPct: Double? = nil, energyWh: Double? = nil) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.hAccM = hAccM
        self.batteryPct = batteryPct
        self.energyWh = energyWh
    }
}

/// One stored ride of the route, as the choice-point detection sees it.
public struct ChoiceRide: Equatable, Sendable {
    public var id: String
    public var startAt: Int64
    public var fixes: [TimedFix]

    public init(id: String, startAt: Int64, fixes: [TimedFix]) {
        self.id = id
        self.startAt = startAt
        self.fixes = fixes
    }
}

public struct ChoiceOption: Equatable, Sendable {
    public var id: String
    public var choicePointId: String
    /// Every 10 m from the split to the rejoin
    public var path: [GeoPoint]
    public var lengthM: Double
    public var name: String
    /// The reference's own stretch ("usual way")
    public var isReference: Bool

    public init(id: String, choicePointId: String, path: [GeoPoint], lengthM: Double, name: String, isReference: Bool) {
        self.id = id
        self.choicePointId = choicePointId
        self.path = path
        self.lengthM = lengthM
        self.name = name
        self.isReference = isReference
    }
}

public struct ChoicePoint: Equatable, Sendable {
    public var id: String
    public var routeId: String
    public var split: GeoPoint
    public var rejoin: GeoPoint
    /// Metres along the reference of the split and the rejoin
    public var posOnRefM: Double
    public var rejoinOnRefM: Double
    /// The reference option first, then by the first ride that took it
    public var options: [ChoiceOption]

    public init(id: String, routeId: String, split: GeoPoint, rejoin: GeoPoint, posOnRefM: Double, rejoinOnRefM: Double,
                options: [ChoiceOption]) {
        self.id = id
        self.routeId = routeId
        self.split = split
        self.rejoin = rejoin
        self.posOnRefM = posOnRefM
        self.rejoinOnRefM = rejoinOnRefM
        self.options = options
    }
}

/// One ride through one choice point (`ride_option`).
public struct RideOptionCost: Equatable, Sendable {
    public var rideId: String
    public var optionId: String
    public var choicePointId: String
    public var timeS: Double
    public var usedPct: Double?
    public var energyWh: Double?

    public init(rideId: String, optionId: String, choicePointId: String, timeS: Double, usedPct: Double? = nil, energyWh: Double? = nil) {
        self.rideId = rideId
        self.optionId = optionId
        self.choicePointId = choicePointId
        self.timeS = timeS
        self.usedPct = usedPct
        self.energyWh = energyWh
    }
}

public struct ChoiceSet: Equatable, Sendable {
    /// In route order (split position on the reference)
    public var points: [ChoicePoint]
    public var costs: [RideOptionCost]

    public init(points: [ChoicePoint], costs: [RideOptionCost]) {
        self.points = points
        self.costs = costs
    }

    public static let empty = ChoiceSet(points: [], costs: [])

    public func option(id: String) -> ChoiceOption? {
        for p in points { if let o = p.options.first(where: { $0.id == id }) { return o } }
        return nil
    }
}

public enum ChoicePointDetector {
    /// M12: a ride "leaves" the reference when it is more than this far from it
    public static let leaveM = 30.0
    /// M12: splits and rejoins of different rides within this distance are one choice point
    public static let clusterM = 40.0
    /// M12: option paths within this distance of each other are the same option
    public static let sameOptionM = 30.0
    /// Share of points that must be within `sameOptionM`, both ways
    public static let sameOptionShare = 0.80
    /// An off stretch counts from this many 10 m points (40 m): shorter ones are GPS noise
    public static let minOffPoints = 4
    /// Points inside the corridor may bridge an off stretch by up to this many points (as M12 variants)
    public static let bridgePoints = 3
    /// A ride's time on an option is believed between these average speeds (m/s)
    public static let plausibleMps: ClosedRange<Double> = 0.5...20

    // MARK: Timed path

    struct TimedPoint: Equatable {
        var point: GeoPoint
        var t: Double
        var pct: Double?
        var wh: Double?
        /// Interpolated across a GPS gap (> 150 m between good fixes): never used as an option path
        var gap: Bool
    }

    /// Good fixes (T28) every 10 m, with time, battery and energy interpolated.
    static func timedPath(_ fixes: [TimedFix], stepM: Double = TripBuilder.pathStepM) -> [TimedPoint] {
        var good: [TimedFix] = []
        for f in fixes.sorted(by: { $0.t < $1.t }) {
            if let a = f.hAccM, a > T.t28GoodFixM { continue }
            if let l = good.last, l.lat == f.lat, l.lon == f.lon { continue }
            good.append(f)
        }
        func point(_ f: TimedFix) -> TimedPoint {
            TimedPoint(point: GeoPoint(lat: f.lat, lon: f.lon), t: f.t, pct: f.batteryPct, wh: f.energyWh, gap: false)
        }
        guard good.count >= 2 else { return good.map(point) }
        func lerp(_ a: Double?, _ b: Double?, _ f: Double) -> Double? {
            guard let a, let b else { return nil }
            return a + (b - a) * f
        }
        var out: [TimedPoint] = [point(good[0])]
        var carried = 0.0
        for i in 1..<good.count {
            let a = good[i - 1]
            let b = good[i]
            let pa = GeoPoint(lat: a.lat, lon: a.lon)
            let pb = GeoPoint(lat: b.lat, lon: b.lon)
            let seg = Geo.distanceM(pa, pb)
            if seg <= 0 { continue }
            let gap = seg > TripBuilder.gapM
            var at = stepM - carried
            while at <= seg {
                let f = at / seg
                out.append(TimedPoint(point: GeoPoint(lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f),
                                      t: a.t + (b.t - a.t) * f, pct: lerp(a.batteryPct, b.batteryPct, f), wh: lerp(a.energyWh, b.energyWh, f),
                                      gap: gap))
                at += stepM
            }
            carried = seg - (at - stepM)
        }
        if let last = good.last, let lastOut = out.last, Geo.distanceM(lastOut.point, GeoPoint(lat: last.lat, lon: last.lon)) > 0.5 {
            out.append(point(last))
        }
        return out
    }

    // MARK: Geometry on the reference

    struct Projection {
        var distanceM: Double
        var posM: Double
    }

    static func cumulative(_ path: [GeoPoint]) -> [Double] {
        var cum = [Double](repeating: 0, count: path.count)
        if path.count < 2 { return cum }
        for i in 1..<path.count { cum[i] = cum[i - 1] + Geo.distanceM(path[i - 1], path[i]) }
        return cum
    }

    /// Distance to the path and the position (metres along it) of the closest point.
    static func project(_ p: GeoPoint, on path: [GeoPoint], cum: [Double]) -> Projection {
        guard let first = path.first else { return Projection(distanceM: .infinity, posM: 0) }
        if path.count == 1 { return Projection(distanceM: Geo.distanceM(p, first), posM: 0) }
        let mLat = Double.pi * Geo.earthRadiusM / 180
        let mLon = mLat * cos(p.lat * Double.pi / 180)
        var best = Projection(distanceM: .infinity, posM: 0)
        for i in 1..<path.count {
            let ax = (path[i - 1].lon - p.lon) * mLon
            let ay = (path[i - 1].lat - p.lat) * mLat
            let bx = (path[i].lon - p.lon) * mLon
            let by = (path[i].lat - p.lat) * mLat
            let dx = bx - ax
            let dy = by - ay
            let len2 = dx * dx + dy * dy
            var t = 0.0
            if len2 > 0 { t = max(0, min(1, -(ax * dx + ay * dy) / len2)) }
            let cx = ax + t * dx
            let cy = ay + t * dy
            let d = (cx * cx + cy * cy).squareRoot()
            if d < best.distanceM { best = Projection(distanceM: d, posM: cum[i - 1] + t * (cum[i] - cum[i - 1])) }
        }
        return best
    }

    /// The point `posM` metres along the path.
    static func point(on path: [GeoPoint], cum: [Double], at posM: Double) -> GeoPoint {
        guard let first = path.first else { return GeoPoint(lat: 0, lon: 0) }
        if posM <= 0 || path.count == 1 { return first }
        for i in 1..<path.count where cum[i] >= posM {
            let len = cum[i] - cum[i - 1]
            let f = len > 0 ? (posM - cum[i - 1]) / len : 0
            let a = path[i - 1]
            let b = path[i]
            return GeoPoint(lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f)
        }
        return path[path.count - 1]
    }

    /// The part of the path between two positions (ends interpolated).
    public static func slice(_ path: [GeoPoint], from a: Double, to b: Double) -> [GeoPoint] {
        let cum = cumulative(path)
        return slice(path, cum: cum, from: a, to: b)
    }

    static func slice(_ path: [GeoPoint], cum: [Double], from a: Double, to b: Double) -> [GeoPoint] {
        guard path.count >= 2, b > a else { return [] }
        var out = [point(on: path, cum: cum, at: a)]
        for i in 0..<path.count where cum[i] > a && cum[i] < b { out.append(path[i]) }
        out.append(point(on: path, cum: cum, at: b))
        return out
    }

    /// Share of `a`'s points within `m` of path `b`
    public static func shareWithin(_ a: [GeoPoint], of b: [GeoPoint], m: Double) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var n = 0
        for p in a where Geo.distanceToPathM(p, b) <= m { n += 1 }
        return Double(n) / Double(a.count)
    }

    /// M12: two option paths are the same option when 80% of each one's points are within 30 m of the other.
    public static func sameOption(_ a: [GeoPoint], _ b: [GeoPoint]) -> Bool {
        shareWithin(a, of: b, m: sameOptionM) >= sameOptionShare && shareWithin(b, of: a, m: sameOptionM) >= sameOptionShare
    }

    /// The farthest a point of `a` gets from path `b` (S2 "options >= 30 m apart" uses it).
    public static func apartM(_ a: [GeoPoint], from b: [GeoPoint]) -> Double {
        var worst = 0.0
        for p in a { worst = max(worst, Geo.distanceToPathM(p, b)) }
        return worst
    }

    // MARK: Detection

    struct Pair {
        var rideId: String
        var splitPos: Double
        var rejoinPos: Double
    }

    struct Cluster {
        var id: String
        var anchorSplit: Double
        var anchorRejoin: Double
        var split: Double
        var rejoin: Double
        var firstStartAt: Int64
    }

    /// Off stretches of one ride: (first off index, last off index), with the bridging rule of M12.
    static func offStretches(_ flags: [Bool], gaps: [Bool]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        while i < flags.count {
            if !flags[i] {
                i += 1
                continue
            }
            var end = i
            var j = i + 1
            var bridge = 0
            while j < flags.count {
                if flags[j] {
                    end = j
                    bridge = 0
                } else {
                    bridge += 1
                    if bridge > bridgePoints { break }
                }
                j += 1
            }
            let off = flags[i...end].filter { $0 }.count
            let hasGap = gaps[i...end].contains(true)
            if off >= minOffPoints && !hasGap && Double(off) / Double(end - i + 1) >= sameOptionShare { out.append((i, end)) }
            i = end + 1
        }
        return out
    }

    /// The choice points of one route and every ride's option there. `reference` = the route's reference variant path,
    /// `routeLengthM` = its usual distance (for the place zones at both ends). Rides are used oldest first (ids follow them).
    public static func detect(routeId: String, reference: [GeoPoint], rides: [ChoiceRide], routeLengthM: Double) -> ChoiceSet {
        let ref = Geo.resample(reference, stepM: TripBuilder.pathStepM)
        guard ref.count >= 2 else { return .empty }
        let cum = cumulative(ref)
        let refLength = cum[cum.count - 1]
        let zone = PlaceMatcher.toleranceM(tripLengthM: max(routeLengthM, refLength))
        let ordered = rides.sorted { ($0.startAt, $0.id) < ($1.startAt, $1.id) }

        // 1-2: split / rejoin pairs of every ride
        var paths: [String: [TimedPoint]] = [:]
        var clusters: [Cluster] = []
        for ride in ordered {
            let tp = timedPath(ride.fixes)
            paths[ride.id] = tp
            guard tp.count >= 2 else { continue }
            let proj = tp.map { project($0.point, on: ref, cum: cum) }
            var flags = [Bool](repeating: false, count: tp.count)
            for i in tp.indices {
                let pos = proj[i].posM
                if pos < zone || pos > refLength - zone { continue }
                flags[i] = proj[i].distanceM > leaveM
            }
            for (a, b) in offStretches(flags, gaps: tp.map(\.gap)) {
                let s = a - 1
                let r = b + 1
                guard s >= 0, r < tp.count, proj[s].distanceM <= leaveM, proj[r].distanceM <= leaveM else { continue }
                let pair = Pair(rideId: ride.id, splitPos: proj[s].posM, rejoinPos: proj[r].posM)
                guard pair.rejoinPos > pair.splitPos + TripBuilder.pathStepM else { continue }
                // 3: one choice point when both ends are within 40 m of an earlier pair's
                if let k = clusters.firstIndex(where: { abs($0.anchorSplit - pair.splitPos) <= clusterM && abs($0.anchorRejoin - pair.rejoinPos) <= clusterM }) {
                    clusters[k].split = min(clusters[k].split, pair.splitPos)
                    clusters[k].rejoin = max(clusters[k].rejoin, pair.rejoinPos)
                } else {
                    let id = "cp:\(routeId):\(ride.id):\(Int((pair.splitPos / 10).rounded()))"
                    clusters.append(Cluster(id: id, anchorSplit: pair.splitPos, anchorRejoin: pair.rejoinPos, split: pair.splitPos,
                                            rejoin: pair.rejoinPos, firstStartAt: ride.startAt))
                }
            }
        }
        // overlapping choice points are one (the combination needs one option per place, not two that share a street)
        clusters.sort { $0.split < $1.split }
        var joined: [Cluster] = []
        for c in clusters {
            if var last = joined.last, c.split < last.rejoin {
                last.rejoin = max(last.rejoin, c.rejoin)
                if c.firstStartAt < last.firstStartAt {
                    last.id = c.id
                    last.firstStartAt = c.firstStartAt
                }
                joined[joined.count - 1] = last
            } else {
                joined.append(c)
            }
        }

        // 4-5: every ride's option at every choice point
        var points: [ChoicePoint] = []
        var costs: [RideOptionCost] = []
        for c in joined {
            let split = point(on: ref, cum: cum, at: c.split)
            let rejoin = point(on: ref, cum: cum, at: c.rejoin)
            let refPath = slice(ref, cum: cum, from: c.split, to: c.rejoin)
            var options = [ChoiceOption(id: c.id + ":ref", choicePointId: c.id, path: refPath, lengthM: Geo.pathLengthM(refPath),
                                        name: "usual way", isReference: true)]
            var used: [String: Int] = [:]
            var mine: [RideOptionCost] = []
            for ride in ordered {
                guard let tp = paths[ride.id], tp.count >= 2 else { continue }
                guard let a = nearestIndex(tp, to: split, from: 0), Geo.distanceM(tp[a].point, split) <= clusterM,
                      let b = nearestIndex(tp, to: rejoin, from: a + 1), Geo.distanceM(tp[b].point, rejoin) <= clusterM else { continue }
                let stretch = Array(tp[a...b])
                guard !stretch.contains(where: \.gap) else { continue }
                let sub = stretch.map(\.point)
                let length = Geo.pathLengthM(sub)
                let time = tp[b].t - tp[a].t
                guard time > 0, plausibleMps.contains(length / time) else { continue }
                var optionIndex = options.firstIndex { sameOption(sub, $0.path) }
                if optionIndex == nil {
                    let k = options.count + 1
                    let name = String(format: "way %d at km %.1f", k, c.split / 1000)
                    options.append(ChoiceOption(id: c.id + ":" + ride.id, choicePointId: c.id, path: sub, lengthM: length, name: name,
                                                isReference: false))
                    optionIndex = options.count - 1
                }
                let o = options[optionIndex!]
                used[o.id, default: 0] += 1
                var usedPct: Double?
                if let p0 = tp[a].pct, let p1 = tp[b].pct { usedPct = max(0, p0 - p1) }
                var wh: Double?
                if let e0 = tp[a].wh, let e1 = tp[b].wh { wh = max(0, e1 - e0) }
                mine.append(RideOptionCost(rideId: ride.id, optionId: o.id, choicePointId: c.id, timeS: time, usedPct: usedPct, energyWh: wh))
            }
            // a place where the rides do not really split (only one option ridden) is no choice point
            let ridden = options.filter { used[$0.id, default: 0] > 0 }
            guard ridden.count >= 2 else { continue }
            points.append(ChoicePoint(id: c.id, routeId: routeId, split: split, rejoin: rejoin, posOnRefM: c.split, rejoinOnRefM: c.rejoin,
                                      options: options.filter { $0.isReference || used[$0.id, default: 0] > 0 }))
            costs += mine
        }
        return ChoiceSet(points: points, costs: costs)
    }

    /// Index of the point closest to `target`, from `start` on.
    static func nearestIndex(_ tp: [TimedPoint], to target: GeoPoint, from start: Int) -> Int? {
        guard start < tp.count else { return nil }
        var best: (Int, Double)?
        for i in start..<tp.count {
            let d = Geo.distanceM(tp[i].point, target)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}
