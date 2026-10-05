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
        runRanges()
        runCard()
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

// MARK: u19, u20 (M2-03, M2-04)

extension RouteCheck {
    private static let monday: Int64 = 20_717        // 20,717 days after 1970-01-01 is a Monday
    private static let dayMs: Int64 = 86_400_000

    private static func stat(_ i: Int, daysAgo: Int, minute: Int = 480, timeS: Double, used: Double?) -> RouteRideStats {
        RouteRideStats(rideId: "c\(i)", startAt: (monday - Int64(daysAgo)) * dayMs + Int64(minute) * 60_000, utcOffsetMin: 0,
                       totalS: timeS, distanceM: 3_700, avgMovingMps: 7, usedPct: used)
    }

    /// u19: usual ranges (M13), noticeably different (M14), Today (M26) with the 10% margin kept apart (T101).
    static func runRanges() {
        let results = CheckResults.shared
        let now = monday * dayMs + 12 * 3_600_000
        let ten = UsualRange.range([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let middleOk = abs((ten?.lo ?? 0) - 1.9) < 1e-9 && abs((ten?.hi ?? 0) - 9.1) < 1e-9 && ten?.full == false
        let few = UsualRange.range([30, 10, 20])
        let fewOk = few?.full == true && few?.lo == 10 && few?.hi == 30
        var many: [RouteRideStats] = []
        for i in 0..<30 { many.append(stat(i, daysAgo: i + 1, timeS: 1_000, used: nil)) }
        many.append(stat(99, daysAgo: 91, timeS: 1_000, used: nil))
        let windowOk = UsualRange.select(many, nowMs: now).count == 20
        let gateOk = UsualRange.range(of: .time, rides: Array(many.prefix(2))) == nil && UsualRange.range(of: .time, rides: Array(many.prefix(3))) != nil
        let edge = UsualRangeValue(lo: 720, hi: 900, median: 800, n: 10, full: false)
        let differentOk = UsualRange.noticeablyDifferent(value: 960, range: edge, minimumStep: UsualRange.minimumTimeStepS) == .above(by: 60)
            && UsualRange.noticeablyDifferent(value: 905, range: edge, minimumStep: UsualRange.minimumTimeStepS) == .within
        let rushOk = DayClock.isRushHour(weekday: 1, minuteOfDay: 7 * 60) && !DayClock.isRushHour(weekday: 1, minuteOfDay: 9 * 60 + 31)
            && !DayClock.isRushHour(weekday: 5, minuteOfDay: 8 * 60)
        var commute: [RouteRideStats] = []
        for i in 0..<6 { commute.append(stat(i, daysAgo: 7 * (i + 1), timeS: 1_000 + Double(i) * 20, used: i < 2 ? 10 : (i < 4 ? 11 : 12))) }
        var todayOk = false
        var marginOk = false
        var widerOk = false
        if case .estimate(let e) = TodayEstimator.estimate(rides: commute, nowMs: now, utcOffsetMin: 0) {
            todayOk = abs(e.timeS - 1_050) < 1e-6 && abs((e.usedPct ?? 0) - 11) < 1e-6
            marginOk = abs((e.neededPct ?? 0) - 12.1) < 1e-6
        }
        if case .estimate(let e) = TodayEstimator.estimate(rides: commute, nowMs: now, utcOffsetMin: 0, timeEffectS: 300) {
            widerOk = e.widerRangeS != nil
        }
        let gatesOk = TodayEstimator.estimate(rides: Array(commute.prefix(2)), nowMs: now, utcOffsetMin: 0) == .notEnough(have: 2, need: 3)
        let ok = middleOk && fewOk && windowOk && gateOk && differentOk && rushOk && todayOk && marginOk && widerOk && gatesOk
        results.set("u19", ok ? .pass : .fail,
                    "middle 80% \(middleOk ? "ok" : "wrong") · under 5 rides min-max \(fewOk ? "ok" : "wrong") · 90 days / newest 20 \(windowOk ? "ok" : "wrong") · "
                    + "gates \(gateOk && gatesOk ? "ok" : "wrong") · noticeably different \(differentOk ? "ok" : "wrong") · rush hour \(rushOk ? "ok" : "wrong") · "
                    + "Today honest \(todayOk ? "ok" : "wrong"), needed % +10% \(marginOk ? "ok" : "wrong"), wider range \(widerOk ? "ok" : "wrong")")
    }

    /// u20: the route card and the Routes list built from rides stored in a temporary database.
    static func runCard() {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u20", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let paths: [[SyntheticRoutes.XY]] = [SyntheticRoutes.main, SyntheticRoutes.main, SyntheticRoutes.main, SyntheticRoutes.main,
                                                  SyntheticRoutes.main, SyntheticRoutes.main, SyntheticRoutes.detour, SyntheticRoutes.detour]
            var savedRoute: String?
            for (i, path) in paths.enumerated() {
                let id = "r\(i)"
                try RouteFixtures.insertRide(temp, id: id, path: path, startAt: now - Int64(paths.count - i) * dayMs, timeS: 540 + Double(i % 3) * 30)
                let r = try RouteProcessor.process(rideId: id, database: temp)
                if i == 1, let rid = r?.routeId {
                    savedRoute = rid
                    try RouteService.save(routeId: rid, database: temp)
                }
            }
            guard let savedRoute, let card = RouteCardLoader.card(routeId: savedRoute, database: temp) else {
                results.set("u20", .fail, "No route card after 8 rides")
                return
            }
            let list = RouteCardLoader.list(database: temp)
            let titleOk = card.title == "Route 1" && card.subtitle.hasPrefix("Saved route")
            let statsOk = card.stats.count == 6 && card.stats.allSatisfy { !$0.filling }
            let todayOk = !card.today.filling && card.today.headline.hasPrefix("Today:")
            let variantsOk = card.variants.count == 2 && card.map.count == 2
            let elevationOk = card.elevation?.otherIsEstimate == true
            let ridesOk = card.totalRides == 8 && card.rides.count == 5
            let listOk = list.saved.count == 1 && list.suggested.isEmpty && list.saved[0].rideCount == 8 && list.saved[0].summary.contains("min")
            let ok = titleOk && statsOk && todayOk && variantsOk && elevationOk && ridesOk && listOk
            results.set("u20", ok ? .pass : .fail,
                        "title \(titleOk ? "ok" : "wrong") · six ranges \(statsOk ? "ok" : "wrong") · Today strip \(todayOk ? "ok" : "wrong") · "
                        + "variants + map \(variantsOk ? "ok" : "wrong") · elevation other way is an estimate \(elevationOk ? "ok" : "wrong") · "
                        + "rides list \(ridesOk ? "ok" : "wrong") · Routes list \(listOk ? "ok" : "wrong")")
        } catch {
            results.set("u20", .fail, "Route card check failed: \(error.localizedDescription)")
        }
    }
}
