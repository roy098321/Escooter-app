import CorckieCore
import Foundation
import Observation

/// F-39 "what is a ride" (note 7): the open trip between legs, on the main thread. A ride with a picked destination that ends
/// short of it leaves the trip open; Home offers "↻ Continue to <place>"; the next leg that arrives at a saved place merges the
/// legs into one ride there (`RideToolsService.merge`, with its undo). The rules are `TripRules` (CorckieCore, Linux tested).
/// The open trip is one small JSON value in UserDefaults; nothing about WHEN the rider rides is kept.
@Observable
final class TripService {
    static let shared = TripService()
    private static let key = "corckie.f39.openTrip"

    private(set) var open: TripRules.OpenTrip?
    /// The destination of the ride on now (picked before the ride, or changed during it)
    @ObservationIgnored private var rideDestinationKey: String?

    private init() {
        open = TripRules.OpenTrip.parse(UserDefaults.standard.string(forKey: Self.key))
    }

    private func set(_ trip: TripRules.OpenTrip?) {
        open = trip
        if let trip { UserDefaults.standard.set(trip.json, forKey: Self.key) } else { UserDefaults.standard.removeObject(forKey: Self.key) }
    }

    static func dayKey(_ date: Date = Date()) -> String {
        RideQueries.dayKey(startAt: Int64(date.timeIntervalSince1970 * 1000), utcOffsetMin: TimeZone.current.secondsFromGMT(for: date) / 60)
    }

    /// Home's "↻ Continue to …" (today only, flaw 2C)
    var offer: TripRules.OpenTrip? { TripRules.offered(open, dayKey: Self.dayKey()) }

    /// Once a second while a ride is on (RecorderService): the destination as it stands
    func noteDestination(_ key: String?) { rideDestinationKey = key }

    /// The rider picked a destination (or No destination) on Home: another one closes the open trip (flaw 2A)
    func picked(key: String?) {
        guard let trip = open else { return }
        let next = TripRules.picked(placeId: placeId(forKey: key), open: trip)
        if next == nil { Log.info(source: "trips", "Open trip to \(trip.placeName) closed: another destination picked") }
        set(next)
    }

    /// "↻ Continue to …" tapped: the trip's place becomes the destination again
    func continueTapped() {
        guard let trip = offer else { return }
        RouteFollowSelection.shared.choose(key: QuickDialLoader.placePrefix + trip.placeId)
    }

    /// A saved place for a destination key: "place:<id>", or the place a saved route ends at
    private func placeId(forKey key: String?) -> String? {
        guard let key else { return nil }
        if let p = QuickDialLoader.placeId(fromKey: key) { return p }
        guard let db = AppModel.shared.database else { return nil }
        return (try? RouteQueries(db).route(id: key))?.toPlaceId
    }

    /// A ride closed (after its places were found): the trip rules decide; the legs of an arrived trip are merged into one ride.
    /// Returns the ride the summary should show (the merged one, or the same).
    func rideClosed(id: String, database: AppDatabase?) -> String {
        defer { rideDestinationKey = nil }
        guard let db = database, !db.isReadOnly else { return id }
        let q = RideQueries(db)
        guard let r = try? q.ride(id: id), !r.isSimulated else { return id }
        let routes = RouteQueries(db)
        let endPlace = (try? routes.endPlaceIds())?[id]
        let fixes = ((try? q.samples(rideId: id)) ?? []).filter { $0.lat != nil && $0.lon != nil }
        let destination = placeId(forKey: rideDestinationKey)
        let destName = destination.flatMap { try? routes.place(id: $0) }.flatMap { $0.name }
        let day = RideQueries.dayKey(startAt: r.endAt ?? r.startAt, utcOffsetMin: r.utcOffsetMin ?? TimeZone.current.secondsFromGMT() / 60)
        let leg = TripRules.Leg(rideId: id, destinationPlaceId: destination, destinationName: destName, endPlaceId: endPlace,
                                startLat: fixes.first?.lat, startLon: fixes.first?.lon, endLat: fixes.last?.lat, endLon: fixes.last?.lon,
                                dayKey: day)
        let decision = TripRules.afterRide(leg, open: open)
        var shown = id
        if let legs = decision.merge, legs.count >= 2 {
            var kept = legs[0]
            for next in legs.dropFirst() {
                do {
                    kept = try RideToolsService.merge(db, firstId: kept, secondId: next)
                } catch {
                    Log.error(source: "trips", "F-39 merge \(kept) + \(next): \(error.localizedDescription)")
                    break
                }
            }
            shown = kept
            Log.info(source: "trips", "F-39: \(legs.count) legs merged into one ride")
        }
        if decision.open != open {
            if let t = decision.open { Log.info(source: "trips", "Open trip to \(t.placeName): \(t.legIds.count) leg(s)") }
        }
        set(decision.open)
        return shown
    }
}
