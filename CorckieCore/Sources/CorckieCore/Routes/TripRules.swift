import Foundation

// MARK: F-39 - what is a ride (note 7, all 7 flaws decided 24 Oct)

/// F-39: a trip is judged by where it ends. With a picked destination, legs split by a scooter-off stop merge into one ride to the
/// place actually reached; without one, legs never merge (picking a destination is what says "one trip"). A trip that has not
/// arrived stays open and is offered as "↻ Continue to <place>" until the rider picks something else, a ride ends at another saved
/// place, or the day ends. Detours and clearly-too-short rides still count as rides there, but do not feed that place's time and
/// battery estimates. Starting guesses (A-07), to verify on real rides in the HUNT-1 week.
public enum TripRules {
    /// Detour (flaw 3): more than this share longer than the usual (median) distance ...
    public static let detourShare = 0.20
    /// ... and at least this much longer, m
    public static let detourMinM = 1_000.0
    /// With fewer rides than this the comparison is with the shortest so far, not the median
    public static let medianFromRides = 3
    /// The next leg must start within this distance of where the open trip's last leg ended (m)
    public static let nextLegWithinM = 300.0
    /// "Your rides end a bit outside …": this many rides ended outside the circle but within 2× its radius
    public static let widenAfterRides = 2

    // MARK: Estimates (flaws 3 and 5)

    /// The distance a ride is compared with: the median of the others (3 rides or more), else the shortest so far.
    public static func usualDistanceM(_ others: [Double]) -> Double? {
        let d = others.filter { $0 > 0 }.sorted()
        guard !d.isEmpty else { return nil }
        if d.count < medianFromRides { return d.first }
        return d.count % 2 == 1 ? d[d.count / 2] : (d[d.count / 2 - 1] + d[d.count / 2]) / 2
    }

    /// Flaw 3: > 20 % AND ≥ 1 km longer than usual
    public static func isDetour(distanceM: Double, othersM: [Double]) -> Bool {
        guard let u = usualDistanceM(othersM) else { return false }
        return distanceM > u * (1 + detourShare) && distanceM - u >= detourMinM
    }

    /// Flaw 5 add-on (the reverse test): > 20 % AND ≥ 1 km shorter than usual
    public static func isTooShort(distanceM: Double, othersM: [Double]) -> Bool {
        guard let u = usualDistanceM(othersM) else { return false }
        return distanceM < u * (1 - detourShare) && u - distanceM >= detourMinM
    }

    /// Whether a ride that ended at a place feeds that place's time / battery estimates: not a detour, and not clearly too short
    /// unless it started at a saved place.
    public static func feedsEstimates(distanceM: Double?, othersM: [Double], startedAtPlace: Bool) -> Bool {
        guard let d = distanceM, d > 0 else { return true }
        if isDetour(distanceM: d, othersM: othersM) { return false }
        if !startedAtPlace, isTooShort(distanceM: d, othersM: othersM) { return false }
        return true
    }

    /// The rides of a place that feed its estimates (each compared with all the others).
    public static func estimateRides(_ rides: [RouteRideStats]) -> [RouteRideStats] {
        rides.filter { r in
            let others = rides.filter { $0.rideId != r.rideId }.compactMap(\.distanceM)
            return feedsEstimates(distanceM: r.distanceM, othersM: others, startedAtPlace: false)
        }
    }

    // MARK: The open trip (flaws 1, 2, 4, 5)

    public struct OpenTrip: Codable, Equatable, Sendable {
        public var placeId: String
        public var placeName: String
        /// The legs so far, oldest first
        public var legIds: [String]
        public var endLat: Double?
        public var endLon: Double?
        /// "2026-10-24" on the rider's clock: the trip closes at the end of the day
        public var dayKey: String

        public init(placeId: String, placeName: String, legIds: [String], endLat: Double?, endLon: Double?, dayKey: String) {
            self.placeId = placeId
            self.placeName = placeName
            self.legIds = legIds
            self.endLat = endLat
            self.endLon = endLon
            self.dayKey = dayKey
        }

        public var json: String {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }

        public static func parse(_ text: String?) -> OpenTrip? {
            text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(OpenTrip.self, from: $0) }
        }
    }

    /// A ride that just closed, as the trip rules see it.
    public struct Leg: Equatable, Sendable {
        public var rideId: String
        /// The saved place picked as the destination (nil = no destination)
        public var destinationPlaceId: String?
        public var destinationName: String?
        /// The saved place the ride's last movement is inside (arrived), nil = none
        public var endPlaceId: String?
        public var startLat: Double?
        public var startLon: Double?
        public var endLat: Double?
        public var endLon: Double?
        public var dayKey: String

        public init(rideId: String, destinationPlaceId: String?, destinationName: String?, endPlaceId: String?,
                    startLat: Double?, startLon: Double?, endLat: Double?, endLon: Double?, dayKey: String) {
            self.rideId = rideId
            self.destinationPlaceId = destinationPlaceId
            self.destinationName = destinationName
            self.endPlaceId = endPlaceId
            self.startLat = startLat
            self.startLon = startLon
            self.endLat = endLat
            self.endLon = endLon
            self.dayKey = dayKey
        }
    }

    public struct Decision: Equatable, Sendable {
        /// The legs to merge into one ride, oldest first (nil = nothing to merge)
        public var merge: [String]?
        /// The trip that stays open afterwards (offered as "↻ Continue to …")
        public var open: OpenTrip?
    }

    /// After a ride closes: merge the open trip's legs when this one arrived at a saved place, keep the trip open when it did not,
    /// open one when a ride with a destination ended short of it.
    public static func afterRide(_ leg: Leg, open: OpenTrip?) -> Decision {
        var trip = open
        if let t = trip, t.dayKey != leg.dayKey { trip = nil }                         // flaw 2C: end of day
        if let t = trip, let a = t.endLat, let b = t.endLon, let c = leg.startLat, let d = leg.startLon,
           Geo.distanceM(GeoPoint(lat: a, lon: b), GeoPoint(lat: c, lon: d)) > nextLegWithinM { trip = nil }   // started somewhere else: another trip
        if var t = trip {
            if leg.endPlaceId != nil {
                return Decision(merge: t.legIds + [leg.rideId], open: nil)             // arrived (at the place or another one, flaw 4)
            }
            t.legIds.append(leg.rideId)
            t.endLat = leg.endLat
            t.endLon = leg.endLon
            return Decision(merge: nil, open: t)
        }
        // flaw 5: no destination = never merge; flaw 4: ended at another saved place = a normal ride there
        guard let dest = leg.destinationPlaceId, leg.endPlaceId == nil else { return Decision(merge: nil, open: nil) }
        return Decision(merge: nil, open: OpenTrip(placeId: dest, placeName: leg.destinationName ?? "your destination", legIds: [leg.rideId],
                                                   endLat: leg.endLat, endLon: leg.endLon, dayKey: leg.dayKey))
    }

    /// Flaw 2A: picking another destination, or "No destination", closes the open trip; picking the same place keeps it.
    public static func picked(placeId: String?, open: OpenTrip?) -> OpenTrip? {
        guard let t = open, placeId == t.placeId else { return nil }
        return t
    }

    /// The open trip still offered today (flaw 2C)
    public static func offered(_ open: OpenTrip?, dayKey: String) -> OpenTrip? {
        guard let t = open, t.dayKey == dayKey else { return nil }
        return t
    }

    /// Flaw 1: "↻ Continue to Uni"
    public static func continueText(_ trip: OpenTrip) -> String { "\u{21BB} Continue to \(trip.placeName)" }

    // MARK: Ride summary and place screen (flaws 6 and 7)

    /// Flaw 7, the owner's wording exactly: "Includes a 25 min stop, trim it?" (scooter-off stops between merged legs only)
    public static func stopTrimLine(stopS: Double) -> String? {
        let min = Int((stopS / 60).rounded())
        guard min >= 1 else { return nil }
        return "Includes a \(min) min stop, trim it?"
    }

    /// Flaw 6: rides keep ending just outside the place: 2 rides ended outside its circle but within 2× its radius.
    public static func widenOffer(endDistancesM: [Double], radiusM: Double) -> Bool {
        endDistancesM.filter { $0 > radiusM && $0 <= 2 * radiusM }.count >= widenAfterRides
    }

    public static func widenText(placeName: String) -> String { "Your rides end a bit outside \(placeName). Widen it?" }

    /// The circle the offer would set: the first of `choices` that holds the rides ending just outside; nil = no offer.
    public static func widenRadius(endDistancesM: [Double], radiusM: Double, choices: [Double]) -> Double? {
        guard widenOffer(endDistancesM: endDistancesM, radiusM: radiusM) else { return nil }
        let need = endDistancesM.filter { $0 > radiusM && $0 <= 2 * radiusM }.max() ?? radiusM
        return choices.sorted().first { $0 >= need && $0 > radiusM } ?? (need / 50).rounded(.up) * 50
    }
}
