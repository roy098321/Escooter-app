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
        runFit()
        runArrival()
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

// MARK: u21 (M2-05)

extension RouteCheck {
    /// u21: greying with the safety margin (M27, G2): the edges, then the Routes list built from rides in a temporary database
    /// (6 rides each way, 6% a ride, so one way needs 6.6% + 5% reserve = 11.6%, the round trip 18.2%).
    static func runFit() {
        let results = CheckResults.shared
        let edgeOk = RouteFit.evaluate(thereNeededPct: 11, backNeededPct: nil, battery: BatteryNow(pct: 16)).greyed == false
            && RouteFit.evaluate(thereNeededPct: 11, backNeededPct: nil, battery: BatteryNow(pct: 15.9)).greyed
            && RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: BatteryNow(pct: 26.9)).chip == "One way only"
            && RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: BatteryNow(pct: 36.9)).chip == "Tight"
            && RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: BatteryNow(pct: 37)).status == .fits
        let gateOk = RouteFit.evaluate(thereNeededPct: nil, backNeededPct: 11, battery: BatteryNow(pct: 5)) == .silent
            && RouteFit.evaluate(thereNeededPct: 11, backNeededPct: 11, battery: nil) == .silent
        let ageOk = BatteryNow(pct: 64, ageMin: 120).text == "64% (2 h ago)"

        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u21", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let paths = (0..<6).map { _ in SyntheticRoutes.main } + (0..<6).map { _ in SyntheticRoutes.reversed(SyntheticRoutes.main) }
            for (i, path) in paths.enumerated() {
                let id = "f\(i)"
                try RouteFixtures.insertRide(temp, id: id, path: path, startAt: now - Int64(paths.count - i) * 86_400_000)
                try RouteProcessor.process(rideId: id, database: temp)
            }
            let store = RouteQueries(temp)
            let routes = try store.routes()
            for r in routes { try RouteService.save(routeId: r.id, database: temp) }
            func row(_ pct: Double, age: Int? = nil) -> RouteListRow? {
                RouteCardLoader.list(database: temp, battery: BatteryNow(pct: pct, ageMin: age)).saved.first { $0.title == "Route 1" }
            }
            let one = row(15)?.fit.chip == "One way only" && row(15)?.fit.greyed == false
            let grey = row(11)?.fit.greyed == true && row(11)?.fit.chip == "Not enough battery"
            let tight = row(25)?.fit.chip == "Tight"
            let fits = row(40)?.fit.status == .fits
            let oldReading = row(11, age: 180)?.fit.detail?.contains("3 h ago") == true
            var chargeOk = false
            if let route = routes.first, let to = route.toPlaceId {
                try PlaceService.setCanCharge(placeId: to, canCharge: true, database: temp)
                chargeOk = row(25)?.fit.status == .fits && row(15)?.fit.chip == "Tight"
            }
            let ok = edgeOk && gateOk && ageOk && one && grey && tight && fits && oldReading && chargeOk
            results.set("u21", ok ? .pass : .fail,
                        "edges at the limit \(edgeOk ? "ok" : "wrong") · gates \(gateOk ? "ok" : "wrong") · age text \(ageOk ? "ok" : "wrong") · "
                        + "one way only \(one ? "ok" : "wrong") · greyed \(grey ? "ok" : "wrong") · tight \(tight ? "ok" : "wrong") · fits \(fits ? "ok" : "wrong") · "
                        + "last seen with its age \(oldReading ? "ok" : "wrong") · I can charge here \(chargeOk ? "ok" : "wrong")")
        } catch {
            results.set("u21", .fail, "Routes greying check failed: \(error.localizedDescription)")
        }
    }
}

// MARK: u22 (M2-06), u24 (M2-08)

extension RouteCheck {
    private static func geo(_ p: SyntheticRoutes.XY) -> GeoPoint {
        let c = SyntheticRoutes.coordinate(p)
        return GeoPoint(lat: c.lat, lon: c.lon)
    }

    /// u22: Where to? chips and the arrival time from position and pace (M28) on 6 made-up commutes in a temporary database.
    /// u24: the dot keeps moving along the followed route by wheel distance without GPS, stays frozen off the route (P3 D2).
    static func runArrival() {
        let results = CheckResults.shared
        let temp: AppDatabase
        do {
            temp = try AppDatabase.openTemporary(build: AppInfo.build)
        } catch {
            results.set("u22", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            results.set("u24", .fail, "Could not open the temporary database: \(error.localizedDescription)")
            return
        }
        defer { temp.discardTemporary() }
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for i in 0..<6 {
                let id = "w\(i)"
                try RouteFixtures.insertRide(temp, id: id, path: SyntheticRoutes.main, startAt: now - Int64(6 - i) * 86_400_000)
                try RouteProcessor.process(rideId: id, database: temp)
            }
            let store = RouteQueries(temp)
            let beforeSave = RouteFollowLoader.chips(database: temp).isEmpty
            for r in try store.routes() { try RouteService.save(routeId: r.id, database: temp) }
            let chips = RouteFollowLoader.chips(database: temp)
            let chipOk = beforeSave && chips.count == 1 && chips[0].detail.contains("today ~")
            guard let routeId = chips.first?.routeId, var f = RouteFollowLoader.follower(routeId: routeId, database: temp) else {
                results.set("u22", .fail, "No chip or no followed path from 6 saved commutes (chips \(chips.count))")
                results.set("u24", .fail, "No followed path to test")
                return
            }
            let total = f.totalM
            let today = f.todayS
            func at(_ along: Double) -> GeoPoint { geo(SyntheticRoutes.point(on: SyntheticRoutes.main, at: along)) }
            _ = f.update(position: at(0), gpsFresh: true, rideDistanceM: 0, elapsedS: 0)
            let half = f.update(position: at(total / 2), gpsFresh: true, rideDistanceM: total / 2, elapsedS: today / 2)
            let paceOk = abs(half.remainingS - today / 2) < today * 0.06 && !half.offPath
            var late = f
            let slow = late.update(position: at(2_000), gpsFresh: true, rideDistanceM: 2_000, elapsedS: 2_000 / total * today * 1.5)
            let base = (total - 2_000) / total * today
            let lateOk = slow.remainingS > base * 1.1 && slow.remainingS < base * 1.5
            var off = f
            let away = off.update(position: geo((x: 5_000, y: 1_000)), gpsFresh: true, rideDistanceM: 3_000, elapsedS: today)
            let offOk = away.offPath && away.remainingS > 0
            var disp = ArrivalDisplay()
            let a1 = disp.show(remainingS: 600, nowS: 1_000)
            let throttleOk = disp.show(remainingS: 590, nowS: 1_010) == a1 && disp.show(remainingS: 500, nowS: 1_015) != a1
            let ok = chipOk && paceOk && lateOk && offOk && throttleOk
            results.set("u22", ok ? .pass : .fail,
                        "chip appears only once a route is saved \(chipOk ? "ok" : "wrong") · on pace \(paceOk ? "ok" : "wrong") · running late \(lateOk ? "ok" : "wrong") · "
                        + "off the route \(offOk ? "ok" : "wrong") · display throttle \(throttleOk ? "ok" : "wrong")")

            // u24
            var g = try loadFollower(routeId: routeId, temp: temp)
            _ = g.update(position: at(500), gpsFresh: true, rideDistanceM: 500, elapsedS: 70)
            let dr = g.update(position: at(500), gpsFresh: false, rideDistanceM: 2_500, elapsedS: 350)
            let dotOk = dr.deadReckoned && dr.dot.map { Geo.distanceM($0, at(2_500)) < 30 } == true
            var h = try loadFollower(routeId: routeId, temp: temp)
            _ = h.update(position: geo((x: 5_000, y: 0)), gpsFresh: true, rideDistanceM: 100, elapsedS: 15)
            let frozen = h.update(position: geo((x: 5_000, y: 0)), gpsFresh: false, rideDistanceM: 900, elapsedS: 120)
            let frozenOk = !frozen.deadReckoned && frozen.dot == nil
            var driver = LiveScreenDriver()
            driver.follow(try loadFollower(routeId: routeId, temp: temp), utcOffsetMin: 0)
            let p = at(500)
            _ = driver.update(LiveInput(scooterSpeedKmh: 25, phase: .riding, lat: p.lat, lon: p.lon, rideElapsedS: 70, rideDistanceM: 500), at: 100)
            let s = driver.update(LiveInput(scooterSpeedKmh: 25, secondsWithoutGps: 20, phase: .riding, lat: p.lat, lon: p.lon, rideElapsedS: 140, rideDistanceM: 1_500), at: 170)
            let driverOk = s.dotHollow && s.dotOverride != nil && s.arrival?.deadReckoned == true
            let ok24 = dotOk && frozenOk && driverOk
            results.set("u24", ok24 ? .pass : .fail,
                        "dot within 30 m after 2 km without GPS \(dotOk ? "ok" : "wrong") · frozen off the route \(frozenOk ? "ok" : "wrong") · "
                        + "hollow dot + arrival strip from the live rules \(driverOk ? "ok" : "wrong")")
        } catch {
            results.set("u22", .fail, "Arrival check failed: \(error.localizedDescription)")
            results.set("u24", .fail, "Dead reckoning check failed: \(error.localizedDescription)")
        }
    }

    private static func loadFollower(routeId: String, temp: AppDatabase) throws -> RouteFollower {
        guard let f = RouteFollowLoader.follower(routeId: routeId, database: temp) else {
            throw NSError(domain: "RouteCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "no followed path"])
        }
        return f
    }
}
