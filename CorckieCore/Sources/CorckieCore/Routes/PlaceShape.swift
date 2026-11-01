import Foundation

/// Note 18 (owner, Mon 26 Oct, from B66): a place is a Circle (the default) or an Outline the rider draws like Google Earth (tap to add
/// points, drag them, midpoint handles insert, undo, reset, area). The outline replaces the circle everywhere: arrival ("you crossed
/// in"), "you're here", Where to? and the B66 rule. A ride that stays inside one outline is an "Around <place>" ride: in the Rides
/// list, left out of trip time / battery estimates / destination learning. Pure, so it is tested on Linux.
public enum PlaceOutline {
    /// Fewer points than this are no outline (the circle is used)
    public static let minPoints = 3
    /// At most this many points (a building or a campus, not a country)
    public static let maxPoints = 40
    /// An "Around" ride keeps at least this share of its path inside the outline (GPS wobbles at the edge)
    public static let aroundInsideShare = 0.9

    public static func isValid(_ points: [GeoPoint]?) -> Bool { (points?.count ?? 0) >= minPoints }

    /// Local metres around the first point (east, north): plenty exact for a place
    static func xy(_ p: GeoPoint, origin o: GeoPoint) -> (x: Double, y: Double) {
        let k = 111_320.0
        return ((p.lon - o.lon) * k * cos(o.lat * .pi / 180), (p.lat - o.lat) * k)
    }

    /// Ray casting: is the point inside the outline (its edge counts as inside)
    public static func contains(_ poly: [GeoPoint], _ point: GeoPoint) -> Bool {
        guard poly.count >= minPoints else { return false }
        let o = poly[0]
        let p = xy(point, origin: o)
        let v = poly.map { xy($0, origin: o) }
        var inside = false
        var j = v.count - 1
        for i in 0..<v.count {
            let a = v[i], b = v[j]
            if onSegment(p, a, b) { return true }
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func onSegment(_ p: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Bool {
        let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        guard abs(cross) < 0.01 else { return false }
        return p.x >= min(a.x, b.x) - 0.01 && p.x <= max(a.x, b.x) + 0.01 && p.y >= min(a.y, b.y) - 0.01 && p.y <= max(a.y, b.y) + 0.01
    }

    /// m² (shoelace in local metres)
    public static func areaM2(_ poly: [GeoPoint]) -> Double {
        guard poly.count >= minPoints else { return 0 }
        let v = poly.map { xy($0, origin: poly[0]) }
        var sum = 0.0
        for i in 0..<v.count {
            let a = v[i], b = v[(i + 1) % v.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// "850 m²", "1.2 ha", "2.3 km²"
    public static func areaText(_ m2: Double) -> String {
        if m2 < 10_000 { return "\(Int((m2 / 10).rounded()) * 10) m\u{00B2}" }
        if m2 < 1_000_000 { return String(format: "%.1f ha", m2 / 10_000) }
        return String(format: "%.1f km\u{00B2}", m2 / 1_000_000)
    }

    /// The middle of the points (the place's pin and "distance to" point)
    public static func centre(_ poly: [GeoPoint]) -> GeoPoint? {
        guard !poly.isEmpty else { return nil }
        return GeoPoint(lat: poly.map(\.lat).reduce(0, +) / Double(poly.count), lon: poly.map(\.lon).reduce(0, +) / Double(poly.count))
    }

    /// Share of the path points inside (0 for an empty path)
    public static func insideShare(_ path: [GeoPoint], _ poly: [GeoPoint]) -> Double {
        guard !path.isEmpty else { return 0 }
        return Double(path.filter { contains(poly, $0) }.count) / Double(path.count)
    }

    // MARK: Stored in the setting table (no schema change)

    public static let keyPrefix = "place.outline."
    public static func key(placeId: String) -> String { keyPrefix + placeId }

    public static func json(_ poly: [GeoPoint]) -> String {
        (try? JSONEncoder().encode(poly)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    public static func parse(_ json: String?) -> [GeoPoint]? {
        guard let data = json?.data(using: .utf8), let p = try? JSONDecoder().decode([GeoPoint].self, from: data), isValid(p) else { return nil }
        return p
    }
}

/// Note 18: the words of a ride that stayed inside one outline
public enum AroundRide {
    /// "Around Uni"
    public static func title(_ placeName: String) -> String { "Around \(placeName)" }
}

/// One place's shape for every "is it inside" question
public struct PlaceShape: Equatable, Sendable {
    public var center: GeoPoint
    /// nil = automatic circle
    public var radiusM: Double?
    /// ≥ 3 points = Outline (replaces the circle)
    public var outline: [GeoPoint]?

    public init(center: GeoPoint, radiusM: Double? = nil, outline: [GeoPoint]? = nil) {
        self.center = center
        self.radiusM = radiusM
        self.outline = PlaceOutline.isValid(outline) ? outline : nil
    }

    public var isOutline: Bool { outline != nil }

    public func contains(_ p: GeoPoint, automaticRadiusM: Double = PlaceHere.automaticRadiusM) -> Bool {
        if let poly = outline { return PlaceOutline.contains(poly, p) }
        return Geo.distanceM(p, center) <= (radiusM ?? automaticRadiusM)
    }
}

/// The outline editor's state (Google Earth style): tap adds a point, a point drags, a midpoint handle inserts, undo, reset.
public struct OutlineEditor: Equatable, Sendable {
    public private(set) var points: [GeoPoint]
    private var history: [[GeoPoint]] = []
    private let original: [GeoPoint]

    public init(points: [GeoPoint] = []) {
        self.points = points
        self.original = points
    }

    public var canUndo: Bool { !history.isEmpty }
    public var isValid: Bool { PlaceOutline.isValid(points) }
    public var canAdd: Bool { points.count < PlaceOutline.maxPoints }

    /// "Area 1.2 ha"; nil before 3 points
    public var areaLine: String? { isValid ? "Area " + PlaceOutline.areaText(PlaceOutline.areaM2(points)) : nil }

    private mutating func remember() {
        history.append(points)
        if history.count > 100 { history.removeFirst() }
    }

    /// Tap on the map: a new point at the end (the outline closes back to the first)
    public mutating func add(_ p: GeoPoint) {
        guard canAdd else { return }
        remember()
        points.append(p)
    }

    /// A finished drag of point `i` (one undo step per drag)
    public mutating func move(_ i: Int, to p: GeoPoint) {
        guard points.indices.contains(i), points[i] != p else { return }
        remember()
        points[i] = p
    }

    /// The handle between point `i` and the next one becomes a point there
    public mutating func insertMidpoint(after i: Int) {
        guard points.indices.contains(i), points.count >= 2, canAdd else { return }
        let j = (i + 1) % points.count
        remember()
        points.insert(Self.mid(points[i], points[j]), at: i + 1)
    }

    public mutating func undo() {
        guard let last = history.popLast() else { return }
        points = last
    }

    /// Back to no points (undo brings them back)
    public mutating func reset() {
        guard !points.isEmpty else { return }
        remember()
        points = []
    }

    /// The handles between neighbours (the closing edge too once there are 3 points): index of the first point + where
    public var midpoints: [(after: Int, point: GeoPoint)] {
        guard points.count >= 2 else { return [] }
        let edges = points.count >= PlaceOutline.minPoints ? points.count : points.count - 1
        return (0..<edges).map { i in (i, Self.mid(points[i], points[(i + 1) % points.count])) }
    }

    static func mid(_ a: GeoPoint, _ b: GeoPoint) -> GeoPoint { GeoPoint(lat: (a.lat + b.lat) / 2, lon: (a.lon + b.lon) / 2) }

    public var changed: Bool { points != original }
}
