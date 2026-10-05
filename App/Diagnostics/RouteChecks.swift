import CorckieCore
import CorckieSim
import Foundation

/// M2 in-app checks on made-up rides (synthetic map, open sea) in a temporary database: the real database is never touched.
/// u17 places + matching (M2-01), u18 variants + names (M2-02).
enum RouteCheck {
    private static let base: Int64 = 1_790_000_000_000
    private static let day: Int64 = 86_400_000

    /// A ride on the fake map, written and processed like a real one (the Recorder calls the same processor at every ride close).
    private static func ride(_ db: AppDatabase, _ id: String, _ path: [SyntheticRoutes.XY], _ k: Int64, noGps: Int = 0) throws -> RouteProcessResult? {
        try RouteFixtures.insertRide(db, id: id, path: path, startAt: base + k * day, noGpsFirstSeconds: noGps)
        return try RouteProcessor.process(rideId: id, database: db)
    }

    static func runAll() {
        runMatching()
        runVariants()
    }

    // MARK: u17

    static func runMatching() {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u17", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let main = SyntheticRoutes.main
            let store = RouteQueries(temp)
            let toleranceOk = PlaceMatcher.toleranceM(tripLengthM: 1_000) == 100 && PlaceMatcher.toleranceM(tripLengthM: 4_000) == 200
                && PlaceMatcher.toleranceM(tripLengthM: 60_000) == 1_000
            let a = try ride(temp, "a", main, 0)
            let b = try ride(temp, "b", main, 1)
            let suggestOk = a?.outcome == .pending && b?.outcome == .suggested && b?.ridesOnRoute == 2
            let counts = try store.counts()
            let placesOk = counts.places == 2 && counts.routes == 1
            if let routeId = b?.routeId { try RouteService.save(routeId: routeId, database: temp) }
            let moved = try ride(temp, "c", SyntheticRoutes.offset(main, by: (x: 120, y: 0)), 2)
            let parkedOk = moved?.outcome == .matched && moved?.routeId == b?.routeId
            let loop = try ride(temp, "l", SyntheticRoutes.loop, 3)
            let loopOk = loop?.outcome == .loop
            let noGps = try ride(temp, "n", main, 4, noGps: 200)
            let noGpsOk = noGps?.outcome == .noGps
            let far = SyntheticRoutes.offset(main, by: (x: 8_000, y: 0))
            _ = try ride(temp, "x1", far, 5)
            let x2 = try ride(temp, "x2", far, 6)
            if let id = x2?.routeId { try RouteService.dismiss(routeId: id, database: temp) }
            let x3 = try ride(temp, "x3", far, 7)
            let routesAfterDismiss = try store.counts().routes
            let dismissedOk = x3?.outcome == .dismissedRoute && routesAfterDismiss == 2
            let ms = x3?.milliseconds ?? 0
            let ok = toleranceOk && suggestOk && placesOk && parkedOk && loopOk && noGpsOk && dismissedOk
            results.set("u17", ok ? .pass : .fail,
                        "tolerance 100 m–1 km \(toleranceOk ? "ok" : "wrong") · 2nd trip suggests \(suggestOk && placesOk ? "ok" : "wrong") · parked 120 m away "
                        + "\(parkedOk ? "matches" : "does not match") · loop \(loopOk ? "ok" : "wrong") · no GPS \(noGpsOk ? "ok" : "wrong") · "
                        + "dismissed stays \(dismissedOk ? "ok" : "wrong") · \(ms) ms for the last ride")
        } catch {
            results.set("u17", .fail, "Route check failed: \(error.localizedDescription)")
        }
    }

    // MARK: u18

    static func runVariants() {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u18", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let main = SyntheticRoutes.main
            let store = RouteQueries(temp)
            _ = try ride(temp, "a", main, 0)
            let b = try ride(temp, "b", main, 1)
            guard let routeId = b?.routeId else {
                results.set("u18", .fail, "No route after two trips")
                return
            }
            try RouteService.save(routeId: routeId, database: temp)
            let c = try ride(temp, "c", SyntheticRoutes.detour, 2)
            let d = try ride(temp, "d", SyntheticRoutes.detour, 3)
            let variants = try store.variants(routeId: routeId)
            let detourOk = c?.newVariantIds.count == 1 && d?.newVariantIds.isEmpty == true && c?.variantId == d?.variantId && variants.count == 2
            // a street name from the phone replaces "Variant 2"; an owner's name stays
            if variants.count == 2 {
                try store.rename(variantId: variants[1].id, name: StreetNaming.variantName(street: StreetNaming.longest(["Herzl", "Herzl", nil]), fallbackIndex: 2),
                                 byHand: false)
                try store.rename(variantId: variants[0].id, name: "Usual way", byHand: true)
            }
            _ = try ride(temp, "e", main, 4)
            let names = try store.variants(routeId: routeId).map { $0.name ?? "" }
            let namesOk = names == ["Usual way", "via Herzl"]
            let pathOk = (variants.last?.polyline.map { Geo.decode($0).count } ?? 0) > 300
            // the way back is its own route
            _ = try ride(temp, "r1", SyntheticRoutes.reversed(main), 5)
            let r2 = try ride(temp, "r2", SyntheticRoutes.reversed(main), 6)
            let totals = try store.counts()
            let backOk = r2?.outcome == .suggested && r2?.routeId != routeId && totals.routes == 2 && totals.places == 2
            // jitter and a different parking spot do not make variants
            let sameOk = try store.variants(routeId: routeId).count == 2
            let ok = detourOk && namesOk && pathOk && backOk && sameOk
            results.set("u18", ok ? .pass : .fail,
                        "detour = new variant \(detourOk ? "ok" : "wrong") · names (street from the phone, owner's kept) \(namesOk ? "ok" : "wrong") · "
                        + "path stored \(pathOk ? "ok" : "wrong") · way back is its own route \(backOk ? "ok" : "wrong") · no extra variants \(sameOk ? "ok" : "wrong")")
        } catch {
            results.set("u18", .fail, "Variant check failed: \(error.localizedDescription)")
        }
    }
}

extension RouteCheck {
    /// q2: how long matching the last real ride took (the Recorder writes it at every ride close).
    static func timing(database: AppDatabase) {
        guard let json = try? RideQueries(database).setting(key: "q2.routeMs"),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = object["ms"] as? Int else { return }
        let pool = object["pool"] as? Int ?? 0
        CheckResults.shared.set("q2", .info, "\(ms) ms to place the last ride on a route, compared with \(pool) earlier rides")
    }
}
