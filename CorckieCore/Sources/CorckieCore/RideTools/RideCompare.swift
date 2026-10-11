import Foundation

/// M5-01: the numbers of one ride that the compare sheet and the auto-suggest need. Plain values, no database.
public struct CompareRide: Equatable, Sendable {
    public var id: String
    public var title: String
    public var startAt: Int64
    public var routeId: String?
    public var variantId: String?
    public var distanceM: Double?
    public var totalS: Double?
    public var movingS: Double?
    public var avgMovingMps: Double?
    public var topSpeedMps: Double?
    public var usedPct: Double?
    public var elevGainM: Double?
    public var energyWhRaw: Double?
    public var startLat: Double?
    public var startLon: Double?
    public var endLat: Double?
    public var endLon: Double?
    public var isSimulated: Bool

    public init(id: String, title: String = "", startAt: Int64 = 0, routeId: String? = nil, variantId: String? = nil,
                distanceM: Double? = nil, totalS: Double? = nil, movingS: Double? = nil, avgMovingMps: Double? = nil,
                topSpeedMps: Double? = nil, usedPct: Double? = nil, elevGainM: Double? = nil, energyWhRaw: Double? = nil,
                startLat: Double? = nil, startLon: Double? = nil, endLat: Double? = nil, endLon: Double? = nil,
                isSimulated: Bool = false) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.routeId = routeId
        self.variantId = variantId
        self.distanceM = distanceM
        self.totalS = totalS
        self.movingS = movingS
        self.avgMovingMps = avgMovingMps
        self.topSpeedMps = topSpeedMps
        self.usedPct = usedPct
        self.elevGainM = elevGainM
        self.energyWhRaw = energyWhRaw
        self.startLat = startLat
        self.startLon = startLon
        self.endLat = endLat
        self.endLon = endLon
        self.isSimulated = isSimulated
    }

    /// Battery per km, only for rides of 1 km or more
    public var pctPerKm: Double? {
        guard let u = usedPct, let d = distanceM, d >= 1_000 else { return nil }
        return u / (d / 1_000)
    }
}

/// One line of the compare table: both values and the plain difference (A minus B).
public struct CompareRow: Equatable, Sendable {
    public var label: String
    public var a: String
    public var b: String
    public var difference: String

    public init(label: String, a: String, b: String, difference: String) {
        self.label = label
        self.a = a
        self.b = b
        self.difference = difference
    }
}

public enum RideCompareBuilder {
    static let dash = "\u{2013}"
    /// Rides with the same start and end (within this) and a similar distance count as the same trip when no route is saved
    public static let sameEndM = 200.0
    public static let sameDistanceShare = 0.20

    /// Same route and variant, same route, similar start and end, or different trips. Words only, no ranking (P-3).
    public static func relation(_ a: CompareRide, _ b: CompareRide) -> String {
        if let ra = a.routeId, ra == b.routeId {
            if let va = a.variantId, va == b.variantId { return "Same route, same variant" }
            return "Same route"
        }
        if similarTrip(a, b) { return "Similar start and end" }
        return "Different trips"
    }

    private static func line(_ label: String, _ x: Double?, _ y: Double?,
                             _ text: (Double) -> String, _ diff: (Double) -> String) -> CompareRow {
        guard let x, let y else {
            return CompareRow(label: label, a: x.map(text) ?? dash, b: y.map(text) ?? dash, difference: dash)
        }
        return CompareRow(label: label, a: text(x), b: text(y), difference: diff(x - y))
    }

    public static func rows(_ a: CompareRide, _ b: CompareRide) -> [CompareRow] {
        var out: [CompareRow] = []
        out.append(line("Time", a.totalS, b.totalS, { RideSummaryBuilder.duration($0) }, { signedDuration($0) }))
        out.append(line("Moving time", a.movingS, b.movingS, { RideSummaryBuilder.duration($0) }, { signedDuration($0) }))
        out.append(line("Distance", a.distanceM, b.distanceM, { RideSummaryBuilder.distance($0) }, { signed($0 / 1_000, "km", 2) }))
        let avgA: Double? = a.avgMovingMps.map { $0 * 3.6 }
        let avgB: Double? = b.avgMovingMps.map { $0 * 3.6 }
        out.append(line("Avg. speed", avgA, avgB, { RideSummaryBuilder.speed($0) }, { signed($0, "km/h", 1) }))
        let topA: Double? = a.topSpeedMps.map { $0 * 3.6 }
        let topB: Double? = b.topSpeedMps.map { $0 * 3.6 }
        out.append(line("Top speed", topA, topB, { RideSummaryBuilder.speed($0) }, { signed($0, "km/h", 1) }))
        out.append(line("Battery used", a.usedPct, b.usedPct, { String(format: "%.0f%%", $0) }, { signed($0, "points", 0) }))
        out.append(line("Battery per km", a.pctPerKm, b.pctPerKm, { String(format: "%.1f%%", $0) }, { signed($0, "points/km", 1) }))
        out.append(line("Climbed", a.elevGainM, b.elevGainM, { String(format: "%.0f m", $0) }, { signed($0, "m", 0) }))
        out.append(line("Energy", a.energyWhRaw, b.energyWhRaw, { String(format: "~%.0f Wh", $0) }, { signed($0, "Wh", 0) }))
        return out
    }

    /// Rides to offer next to `ride`: the same saved route (same variant first, then newest), else the same trip by its ends.
    public static func suggestions(for ride: CompareRide, among all: [CompareRide], limit: Int = 5) -> [CompareRide] {
        let pool = all.filter { $0.id != ride.id && $0.isSimulated == ride.isSimulated && $0.distanceM != nil }
        var picked: [CompareRide] = []
        if let route = ride.routeId {
            picked = pool.filter { $0.routeId == route }
        }
        if picked.isEmpty {
            picked = pool.filter { similarTrip(ride, $0) }
        }
        picked.sort { x, y in
            let sx = ride.variantId != nil && x.variantId == ride.variantId
            let sy = ride.variantId != nil && y.variantId == ride.variantId
            if sx != sy { return sx }
            return x.startAt > y.startAt
        }
        return Array(picked.prefix(limit))
    }

    static func similarTrip(_ a: CompareRide, _ b: CompareRide) -> Bool {
        guard let sla = a.startLat, let slo = a.startLon, let ela = a.endLat, let elo = a.endLon,
              let slb = b.startLat, let sob = b.startLon, let elb = b.endLat, let eob = b.endLon,
              let da = a.distanceM, let db = b.distanceM, da > 0, db > 0 else { return false }
        let s = Geo.distanceM(GeoPoint(lat: sla, lon: slo), GeoPoint(lat: slb, lon: sob))
        let e = Geo.distanceM(GeoPoint(lat: ela, lon: elo), GeoPoint(lat: elb, lon: eob))
        return s <= sameEndM && e <= sameEndM && abs(da - db) / max(da, db) <= sameDistanceShare
    }

    // MARK: Text

    static func signed(_ v: Double, _ unit: String, _ decimals: Int) -> String {
        let factor = pow(10.0, Double(decimals))
        let r = (v * factor).rounded() / factor
        if r == 0 { return "same" }
        let body = String(format: "%.\(decimals)f", abs(r))
        let sign = r > 0 ? "+" : "\u{2212}"
        return "\(sign)\(body) \(unit)"
    }

    static func signedDuration(_ s: Double) -> String {
        let t = Int(abs(s).rounded())
        if t == 0 { return "same" }
        let sign = s > 0 ? "+" : "\u{2212}"
        if t < 60 { return "\(sign)\(t) s" }
        if t < 3_600 { return "\(sign)\(t / 60) min \(String(format: "%02d", t % 60)) s" }
        return "\(sign)\(t / 3_600) h \(String(format: "%02d", t % 3_600 / 60)) min"
    }
}
