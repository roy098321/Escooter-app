import Foundation

/// B61 (owner 22 Oct, build 264): "Home" twice in the Where to? sheet: the place Home, and a grey "H" row of a saved route that ends there
/// but was linked to another (unnamed) place, or a second saved route to Home from somewhere else. Fixed in three layers:
/// (1) a saved route is linked to the saved place its end falls inside (`RouteRelink`, the same "where you ended counts" rule as note 7);
/// (2) the Where to? list never shows two rows for one destination: the route and place rows of one spot are one row;
/// (3) prevention: `duplicates` names any two rows for the same spot or with the same name (tests, Developer check u139).
public enum WhereToDedupe {
    public struct NamedPlace: Equatable, Sendable {
        public var id: String
        public var name: String
        public var center: GeoPoint
        /// nil = automatic (`PlaceHere.automaticRadiusM`)
        public var radiusM: Double?

        public init(id: String, name: String, center: GeoPoint, radiusM: Double?) {
            self.id = id
            self.name = name
            self.center = center
            self.radiusM = radiusM
        }
    }

    /// The same name for the eye: case and spaces do not count ("home ", "Home", "HOME")
    public static func sameName(_ a: String, _ b: String) -> Bool {
        let fa = normal(a)
        return !fa.isEmpty && fa == normal(b)
    }

    static func normal(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Layer 1: the named place whose circle the point falls inside; the nearest centre wins when circles overlap
    public static func placeContaining(_ point: GeoPoint?, places: [NamedPlace]) -> String? {
        guard let point else { return nil }
        let inside = places.map { (id: $0.id, d: Geo.distanceM(point, $0.center), r: $0.radiusM ?? PlaceHere.automaticRadiusM) }
            .filter { $0.d <= $0.r }
        return inside.min { ($0.d, $0.id) < ($1.d, $1.id) }?.id
    }

    /// The saved place a saved route ends at: the place its end falls inside, else its linked place when that one has a name,
    /// else the named place with the same name as the route's label. nil = it ends at no named place.
    public static func endPlace(toPlaceId: String?, end: GeoPoint?, label: String, places: [NamedPlace]) -> String? {
        if let inside = placeContaining(end, places: places) { return inside }
        if let id = toPlaceId, places.contains(where: { $0.id == id }) { return id }
        return places.first { sameName($0.name, label) }?.id
    }

    /// Layer 1 for the stored link: the place a route's `toPlaceId` should point at, or nil to leave it as it is (its end is in no
    /// named place, or it already points at the place it ends in)
    public static func relink(toPlaceId: String?, end: GeoPoint?, places: [NamedPlace]) -> String? {
        guard let inside = placeContaining(end, places: places), inside != toPlaceId else { return nil }
        return inside
    }

    public struct Row: Equatable, Sendable {
        public var key: String
        public var name: String
        public var placeId: String?

        public init(key: String, name: String, placeId: String?) {
            self.key = key
            self.name = name
            self.placeId = placeId
        }
    }

    /// Layer 3: every pair of rows for the same destination, in plain words ("Home twice: same place", "Home twice: same name"); empty = fine
    public static func duplicates(_ rows: [Row]) -> [String] {
        var out: [String] = []
        for (i, a) in rows.enumerated() {
            for b in rows[(i + 1)...] {
                if a.key == b.key { out.append("\(a.name) twice: same key") }
                else if let p = a.placeId, p == b.placeId { out.append("\(a.name) twice: same place") }
                else if sameName(a.name, b.name) { out.append("\(a.name) twice: same name") }
            }
        }
        return out
    }

    /// Layer 2, the last guard: rows with the same name as an earlier one are dropped, a row of a named place being kept over a route
    /// row that ends at no named place. Order is kept otherwise.
    public static func keepOnePerName(_ rows: [Row]) -> [Row] {
        var out: [Row] = []
        for r in rows {
            if let i = out.firstIndex(where: { sameName($0.name, r.name) || ($0.placeId != nil && $0.placeId == r.placeId) }) {
                if out[i].placeId == nil, r.placeId != nil { out[i] = r }
                continue
            }
            out.append(r)
        }
        return out
    }
}
