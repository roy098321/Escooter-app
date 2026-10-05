import Foundation

/// M2-01: a named (or not yet named) spot. `radiusM == nil` = automatic (5% of the trip, T60).
public struct PlaceInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var point: GeoPoint
    public var radiusM: Double?
    public var canCharge: Bool

    public init(id: String, name: String? = nil, point: GeoPoint, radiusM: Double? = nil, canCharge: Bool = false) {
        self.id = id
        self.name = name
        self.point = point
        self.radiusM = radiusM
        self.canCharge = canCharge
    }
}

/// What the route logic needs of one ride's samples, in time order.
public struct RoutePathSample: Equatable, Sendable {
    public var lat: Double?
    public var lon: Double?
    public var hAccM: Double?
    public var odometerKm: Double?

    public init(lat: Double?, lon: Double?, hAccM: Double?, odometerKm: Double?) {
        self.lat = lat
        self.lon = lon
        self.hAccM = hAccM
        self.odometerKm = odometerKm
    }
}

/// The geometry of one ride: where it started and ended (nil = no good GPS there) and its path every 10 m.
public struct TripShape: Equatable, Sendable {
    public var start: GeoPoint?
    public var end: GeoPoint?
    /// Good fixes, resampled every 10 m (M12 "Resample")
    public var path: [GeoPoint]
    /// Two good fixes were more than 150 m apart (GPS lost for a while): the straight line between them is a guess, so
    /// this ride never creates a new variant
    public var hasGap: Bool

    public init(start: GeoPoint?, end: GeoPoint?, path: [GeoPoint], hasGap: Bool = false) {
        self.start = start
        self.end = end
        self.path = path
        self.hasGap = hasGap
    }

    public static let empty = TripShape(start: nil, end: nil, path: [])
}

public enum TripBuilder {
    /// A good fix may be this far (by the wheel odometer) from the ride's start or end and still count as
    /// "the start" / "the end" (M11 S3 says ~100 m; the odometer moves in 0.1 km steps, so 150 m here).
    public static let endZoneM = 150.0
    public static let pathStepM = 10.0
    /// Fixes further apart than this are a GPS gap
    public static let gapM = 150.0

    /// M11: start = first good fix, end = last good fix, each only when the odometer says it is within
    /// `endZoneM` of the ride's first / last odometer reading; otherwise that end is unknown (nil).
    public static func shape(_ samples: [RoutePathSample]) -> TripShape {
        var fixes: [(point: GeoPoint, odo: Double?)] = []
        for s in samples {
            guard let lat = s.lat, let lon = s.lon else { continue }
            if let acc = s.hAccM, acc > T.t28GoodFixM { continue }
            if let last = fixes.last, last.point.lat == lat, last.point.lon == lon { continue }
            fixes.append((GeoPoint(lat: lat, lon: lon), s.odometerKm))
        }
        guard let first = fixes.first, let last = fixes.last else { return .empty }
        let odos = samples.compactMap { $0.odometerKm }
        var startKnown = true
        var endKnown = true
        if let o0 = odos.first, let o1 = odos.last, let f0 = first.odo, let f1 = last.odo {
            startKnown = (f0 - o0) * 1000 <= endZoneM
            endKnown = (o1 - f1) * 1000 <= endZoneM
        }
        let path = Geo.resample(fixes.map { $0.point }, stepM: pathStepM)
        var gap = false
        if fixes.count >= 2 {
            for i in 1..<fixes.count where Geo.distanceM(fixes[i - 1].point, fixes[i].point) > gapM { gap = true }
        }
        return TripShape(start: startKnown ? first.point : nil, end: endKnown ? last.point : nil, path: path, hasGap: gap)
    }
}

public enum PlaceMatcher {
    /// M11 / T60: 5% of the trip length, clamped to 100 m – 1 km.
    public static func toleranceM(tripLengthM: Double) -> Double {
        max(T.t60SamePlaceMinM, min(T.t60SamePlaceMaxM, tripLengthM * T.t60SamePlaceShare))
    }

    /// The radius a place uses for a trip of this length: its own override, else the automatic tolerance.
    public static func radiusM(of place: PlaceInfo, tripLengthM: Double) -> Double {
        place.radiusM ?? toleranceM(tripLengthM: tripLengthM)
    }

    /// Overlaps → the nearest place wins (M11). nil when no place reaches the point.
    public static func nearest(to point: GeoPoint, in places: [PlaceInfo], tripLengthM: Double) -> PlaceInfo? {
        var best: (place: PlaceInfo, d: Double)?
        for p in places {
            let d = Geo.distanceM(point, p.point)
            if d <= radiusM(of: p, tripLengthM: tripLengthM), best == nil || d < best!.d {
                best = (p, d)
            }
        }
        return best?.place
    }

    /// Two points are "the same place" for a trip of this length.
    public static func samePlace(_ a: GeoPoint, _ b: GeoPoint, tripLengthM: Double) -> Bool {
        Geo.distanceM(a, b) <= toleranceM(tripLengthM: tripLengthM)
    }
}
