import Foundation

/// M2-06 / M2-08 (CALC_SPEC M28, P3 D2): where I am along the followed route and when I arrive.
///
/// - On a fix inside the 50 m corridor (T61) the position along the route is the nearest point, searched forward from where
///   I was (a route that doubles back is not confused with its other half).
/// - Remaining = the rest of today's estimate (uniform along the path: the stored rides keep totals, not per-100 m times)
///   x a pace factor 1 + w x (pace - 1), w = km done / (km done + 2) (S1).
/// - Off the route: straight distance to the end / the route's typical speed (S2).
/// - GPS lost on the route (M2-08): the position moves along the route by the wheel distance since the last fix. Off the
///   route, or with no route, nothing moves (M1 behaviour: the dot freezes, greyed).
public struct RouteFollower: Equatable, Sendable {
    public static let corridorM = T.t61CorridorM

    public let destinationName: String
    public let path: [GeoPoint]
    public let totalM: Double
    /// Today's estimate for the whole route (honest, no margin)
    public let todayS: Double
    private let cum: [Double]

    public private(set) var alongM: Double = 0
    private var startAlongM: Double?
    private var anchorAlongM: Double?
    private var anchorRideM: Double?
    private var offPath = false

    public init?(destinationName: String, path: [GeoPoint], todayS: Double) {
        guard path.count >= 2, todayS > 0 else { return nil }
        var c: [Double] = [0]
        for i in 1..<path.count { c.append(c[i - 1] + Geo.distanceM(path[i - 1], path[i])) }
        guard let total = c.last, total > 50 else { return nil }
        self.destinationName = destinationName
        self.path = path
        self.cum = c
        self.totalM = total
        self.todayS = todayS
    }

    public var typicalSpeedMps: Double { totalM / todayS }

    /// The point `along` metres from the start of the route
    public func point(at along: Double) -> GeoPoint {
        let a = min(max(along, 0), totalM)
        var lo = 0
        var hi = cum.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cum[mid] <= a { lo = mid } else { hi = mid }
        }
        let seg = cum[hi] - cum[lo]
        let f = seg > 0 ? (a - cum[lo]) / seg : 0
        return GeoPoint(lat: path[lo].lat + (path[hi].lat - path[lo].lat) * f, lon: path[lo].lon + (path[hi].lon - path[lo].lon) * f)
    }

    /// Nearest point on the route at or after `from` (metres along): (metres along, distance from the route)
    func project(_ p: GeoPoint, from: Double) -> (along: Double, distM: Double) {
        var best = (along: 0.0, distM: Double.infinity)
        let mLon = Geo.mPerDegLat * cos(p.lat * Double.pi / 180)
        for i in 1..<path.count where cum[i] >= from {
            let ax = (path[i - 1].lon - p.lon) * mLon
            let ay = (path[i - 1].lat - p.lat) * Geo.mPerDegLat
            let bx = (path[i].lon - p.lon) * mLon
            let by = (path[i].lat - p.lat) * Geo.mPerDegLat
            let dx = bx - ax
            let dy = by - ay
            let len2 = dx * dx + dy * dy
            var t = 0.0
            if len2 > 0 { t = max(0, min(1, -(ax * dx + ay * dy) / len2)) }
            let d = hypot(ax + t * dx, ay + t * dy)
            if d < best.distM { best = (cum[i - 1] + t * (cum[i] - cum[i - 1]), d) }
        }
        return best
    }

    public struct Step: Equatable, Sendable {
        public var alongM: Double
        public var remainingS: Double
        public var offPath: Bool
        /// The position comes from the wheel distance (no GPS): the dot is drawn hollow at `dot`
        public var deadReckoned: Bool
        /// Where to draw the dot when `deadReckoned`
        public var dot: GeoPoint?
    }

    /// - Parameters:
    ///   - position: the newest fix (may be old); `gpsFresh` says whether it is current
    ///   - rideDistanceM: wheel distance of this ride so far (nil when unknown)
    ///   - elapsedS: seconds since the ride started
    public mutating func update(position: GeoPoint?, gpsFresh: Bool, rideDistanceM: Double?, elapsedS: Double) -> Step {
        var dead = false
        if gpsFresh, let p = position {
            let hit = project(p, from: max(0, alongM - 100))
            if hit.distM <= Self.corridorM {
                offPath = false
                alongM = hit.along
                if startAlongM == nil { startAlongM = hit.along }
                anchorAlongM = hit.along
                anchorRideM = rideDistanceM
            } else {
                offPath = true
                anchorAlongM = nil
                anchorRideM = nil
            }
        } else if let a = anchorAlongM, let r0 = anchorRideM, let r = rideDistanceM, !offPath {
            alongM = min(totalM, a + max(0, r - r0))
            dead = true
        }

        let remainingS: Double
        if offPath, let p = position {
            let end = path[path.count - 1]
            remainingS = Geo.distanceM(p, end) / typicalSpeedMps
        } else {
            let base = (totalM - alongM) / totalM * todayS
            let done = max(0, alongM - (startAlongM ?? alongM))
            let expected = done / totalM * todayS
            var pace = 1.0
            if expected > 20, elapsedS > 0 { pace = min(2, max(0.5, elapsedS / expected)) }
            let kmDone = done / 1000
            let w = kmDone / (kmDone + 2)
            remainingS = base * (1 + w * (pace - 1))
        }
        return Step(alongM: alongM, remainingS: remainingS, offPath: offPath, deadReckoned: dead,
                    dot: dead ? point(at: alongM) : nil)
    }
}

/// T83: the arrival line changes at most every 30 s, or at once when it moves by a minute or more.
public struct ArrivalDisplay: Equatable, Sendable {
    public static let minGapS = 30.0
    public static let jumpS = 60.0
    private var shownArrivalS: Double?
    private var shownAt: Double = 0

    public init() {}

    /// `nowS` = epoch seconds; returns the arrival time (epoch seconds) to show
    public mutating func show(remainingS: Double, nowS: Double) -> Double {
        let arrival = nowS + remainingS
        if let s = shownArrivalS, nowS - shownAt < Self.minGapS, abs(arrival - s) < Self.jumpS { return s }
        shownArrivalS = arrival
        shownAt = nowS
        return arrival
    }
}

public struct ArrivalStrip: Equatable, Sendable {
    /// "Work · arrive ~8:56 · 9 min left"
    public var text: String
    public var offRoute: Bool
    public var deadReckoned: Bool

    public static func text(destination: String, arrivalS: Double, nowS: Double, utcOffsetMin: Int) -> String {
        let local = Int64(arrivalS) + Int64(utcOffsetMin) * 60
        let minute = Int((((local % 86_400) + 86_400) % 86_400) / 60)
        let left = max(1, Int(((arrivalS - nowS) / 60).rounded()))
        return "\(destination) \u{00B7} arrive ~\(DayClock.clockText(minuteOfDay: minute)) \u{00B7} \(left) min left"
    }
}

/// Home "Where to?" (M2-06): one chip per saved route, hidden until a route exists (S2); a tap shows Today for that route.
public struct WhereToInput: Sendable {
    public var routeId: String
    public var title: String
    public var toName: String?
    public var rides: [RouteRideStats]

    public init(routeId: String, title: String, toName: String?, rides: [RouteRideStats]) {
        self.routeId = routeId
        self.title = title
        self.toName = toName
        self.rides = rides
    }
}

public struct WhereToChip: Equatable, Sendable {
    public var routeId: String
    public var label: String
    /// "Work · usual 12 min · today ~13 min · leave now, arrive ~8:56 · uses about 11%" (honest numbers, no margin)
    public var detail: String
}

public enum WhereTo {
    public static func label(toName: String?, title: String) -> String {
        if let n = toName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return title
    }

    public static func chips(_ inputs: [WhereToInput], nowMs: Int64, utcOffsetMin: Int) -> [WhereToChip] {
        inputs.filter { !$0.rides.isEmpty }.map { i in
            let label = label(toName: i.toName, title: i.title)
            let result = TodayEstimator.estimate(rides: i.rides, nowMs: nowMs, utcOffsetMin: utcOffsetMin,
                                                 departureMinute: DayClock.minuteOfDay(startAtMs: nowMs, utcOffsetMin: utcOffsetMin))
            return WhereToChip(routeId: i.routeId, label: label, detail: detail(label: label, result: result, nowMs: nowMs, utcOffsetMin: utcOffsetMin))
        }
    }

    public static func detail(label: String, result: TodayResult, nowMs: Int64, utcOffsetMin: Int) -> String {
        switch result {
        case .notEnough(let have, let need):
            return "\(label) \u{00B7} \(have) of \(need) rides until there is a time estimate"
        case .estimate(let e):
            var parts = [label, "today ~\(RouteCardBuilder.minutes(e.timeS)) min"]
            let arrive = Double(nowMs) / 1000 + e.timeS
            let local = Int64(arrive) + Int64(utcOffsetMin) * 60
            let minute = Int((((local % 86_400) + 86_400) % 86_400) / 60)
            parts.append("leave now, arrive ~\(DayClock.clockText(minuteOfDay: minute))")
            if let u = e.usedPct { parts.append("uses about \(Int(u.rounded()))%") }
            return parts.joined(separator: " \u{00B7} ")
        }
    }
}
