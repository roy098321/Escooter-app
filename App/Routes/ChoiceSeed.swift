import CorckieCore
import Foundation

/// M6-01: the made-up choice-point rides of `ChoiceSamples` (a straight 4 km route in the ocean with a "park" and a "left" detour)
/// written as real rows: a saved route, its reference variant, the rides with their samples (every 2 s). For the check u42 and the
/// app-tests, always in a temporary database. Compiled into AppTests too.
enum ChoiceSeed {
    @discardableResult
    static func route(_ db: AppDatabase, specs: [ChoiceSamples.Spec] = ChoiceSamples.nineRides, routeId: String = ChoiceSamples.routeId,
                      rebuild: Bool = true) throws -> [String] {
        let store = RouteQueries(db)
        try store.save(route: RouteRecord(id: routeId, fromPlaceId: nil, toPlaceId: nil, name: "Seed choice route", usualDistanceM: ChoiceSamples.routeM,
                                          sizeClass: "ride", state: "saved", createdAt: ChoiceSamples.t0))
        try store.save(variant: VariantRecord(id: routeId + "-v1", routeId: routeId, name: "Variant 1", nameByHand: false,
                                              polyline: Geo.encode(Geo.resample(ChoiceSamples.reference, stepM: 10)), isReference: true, isCombination: false))
        let made = ChoiceSamples.rides(specs)
        let rides = RideQueries(db)
        var ids: [String] = []
        for (c, r) in zip(made.choice, made.rides) {
            let id = routeId + "-" + c.id
            var rec = RideRecord(id: id, startAt: c.startAt)
            rec.status = "ended"
            rec.kind = "ride"
            rec.utcOffsetMin = 180
            rec.hasGps = true
            rec.endAt = c.startAt + Int64((r.totalS ?? 0) * 1000)
            rec.totalS = r.totalS
            rec.movingS = r.totalS
            rec.distanceM = ChoiceSamples.routeM
            rec.createdBuild = "test"
            try rides.save(rec)
            var samples: [RideSampleRecord] = []
            var lastT: Int64 = -1
            for f in c.fixes {
                let t = Int64((f.t * 1000).rounded())
                guard t > lastT else { continue }
                lastT = t
                var s = RideSampleRecord(rideId: id, t: t)
                s.lat = f.lat
                s.lon = f.lon
                s.hAccM = f.hAccM
                s.batteryPct = f.batteryPct.map { Int($0.rounded()) }
                s.powerW = 300
                s.speedMps = 6
                s.mode = "scooter"
                samples.append(s)
            }
            try rides.insert(samples: samples)
            try store.setLink(rideId: id, RideRouteLink(routeId: routeId, variantId: routeId + "-v1", startPlaceId: nil, endPlaceId: nil))
            ids.append(id)
        }
        if rebuild { try FastestService.rebuild(db, routeId: routeId) }
        return ids
    }
}
