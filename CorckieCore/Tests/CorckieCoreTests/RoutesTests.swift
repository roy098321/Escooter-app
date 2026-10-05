import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// M2-01 / M2-02: places, matching tolerance (M11), "save as route?" after 2 trips (T63), variants (M12) and their names.
/// Everything runs on the made-up map of `SyntheticRoutes` (no real coordinates).
final class RoutesTests: XCTestCase {
    typealias XY = SyntheticRoutes.XY

    // MARK: helpers

    private func geo(_ p: XY) -> GeoPoint {
        let c = SyntheticRoutes.coordinate(p)
        return GeoPoint(lat: c.lat, lon: c.lon)
    }

    private func shape(_ path: [XY]) -> TripShape {
        let resampled = Geo.resample(path.map { geo($0) }, stepM: 10)
        return TripShape(start: resampled.first, end: resampled.last, path: resampled)
    }

    private var counter = 0
    private func makeID() -> String {
        counter += 1
        return "id\(counter)"
    }

    private func ride(_ id: String, _ path: [XY], at hour: Int64 = 0) -> RoutedRide {
        RoutedRide(id: id, startAt: hour * 3_600_000, distanceM: SyntheticRoutes.pathLength(path), shape: shape(path))
    }

    /// The app's loop: ingest a ride with the rides that are not on a route as the pool.
    private func feed(_ rides: [RoutedRide]) -> (book: RouteBook, outcomes: [String: RideOutcome], assigned: [String: RideAssignment]) {
        var book = RouteBook()
        var assigned: [String: RideAssignment] = [:]
        var outcomes: [String: RideOutcome] = [:]
        var seen: [RoutedRide] = []
        for r in rides {
            let pool = seen.filter { assigned[$0.id]?.routeId == nil }
            let update = book.ingest(r, pool: pool, makeID: { self.makeID() })
            for a in update.assignments where a.routeId != nil { assigned[a.rideId] = a }
            if let first = update.assignments.first { outcomes[r.id] = first.outcome }
            seen.append(r)
        }
        return (book, outcomes, assigned)
    }

    // MARK: Geo

    func test_geo_distance_resample_polyline() {
        let a = GeoPoint(lat: 10, lon: -30)
        let b = geo((x: 0, y: 1000))
        XCTAssertEqual(Geo.distanceM(a, b), 1000, accuracy: 1)
        let pts = Geo.resample([a, b], stepM: 10)
        XCTAssertEqual(pts.count, 101)
        XCTAssertEqual(Geo.pathLengthM(pts), 1000, accuracy: 2)
        let again = Geo.decode(Geo.encode(pts))
        XCTAssertEqual(again.count, pts.count)
        XCTAssertEqual(again[50].lat, pts[50].lat, accuracy: 0.00001)
        XCTAssertEqual(again[50].lon, pts[50].lon, accuracy: 0.00001)
        XCTAssertEqual(Geo.decode(Geo.encode([])).count, 0)
    }

    func test_geo_distanceToPath_usesSegments() {
        let path = [geo((x: 0, y: 0)), geo((x: 0, y: 1000))]
        XCTAssertEqual(Geo.distanceToPathM(geo((x: 40, y: 500)), path), 40, accuracy: 0.5)          // beside the middle
        XCTAssertEqual(Geo.distanceToPathM(geo((x: 0, y: 1300)), path), 300, accuracy: 0.5)         // past the end
    }

    // MARK: M11 tolerance and places

    func test_M11_tolerance_is5PercentClampedTo100mAnd1km() {
        XCTAssertEqual(PlaceMatcher.toleranceM(tripLengthM: 1_000), 100)       // 50 m -> clamped up
        XCTAssertEqual(PlaceMatcher.toleranceM(tripLengthM: 2_000), 100)       // exactly 100
        XCTAssertEqual(PlaceMatcher.toleranceM(tripLengthM: 4_000), 200)
        XCTAssertEqual(PlaceMatcher.toleranceM(tripLengthM: 20_000), 1_000)
        XCTAssertEqual(PlaceMatcher.toleranceM(tripLengthM: 60_000), 1_000)    // clamped down
    }

    func test_M11_nearestPlaceWins_andRadiusOverrideApplies() {
        let p1 = PlaceInfo(id: "p1", point: geo((x: 0, y: 0)))
        let p2 = PlaceInfo(id: "p2", point: geo((x: 150, y: 0)))
        let probe = geo((x: 100, y: 0))
        // both reach it (tolerance 200 m for a 4 km trip): p2 is nearer
        XCTAssertEqual(PlaceMatcher.nearest(to: probe, in: [p1, p2], tripLengthM: 4_000)?.id, "p2")
        // p2 with a 30 m circle no longer reaches it, p1 does
        let small = PlaceInfo(id: "p2", point: geo((x: 150, y: 0)), radiusM: 30)
        XCTAssertEqual(PlaceMatcher.nearest(to: probe, in: [p1, small], tripLengthM: 4_000)?.id, "p1")
        XCTAssertNil(PlaceMatcher.nearest(to: geo((x: 1_000, y: 0)), in: [p1, p2], tripLengthM: 4_000))
    }

    func test_M11_endOfTheRideWithoutGps_isUnknown() {
        // 60 samples every 5 s at 7 m/s; GPS only after 400 m (odometer 0.4 km in)
        var samples: [RoutePathSample] = []
        for i in 0..<60 {
            let odo = 100.0 + Double(i) * 0.035
            let hasFix = i >= 12
            let p = geo((x: 0, y: Double(i) * 35))
            samples.append(RoutePathSample(lat: hasFix ? p.lat : nil, lon: hasFix ? p.lon : nil, hAccM: hasFix ? 5 : nil, odometerKm: odo))
        }
        let s = TripBuilder.shape(samples)
        XCTAssertNil(s.start, "the first good fix came 420 m after the start")
        XCTAssertNotNil(s.end)
        // a fix within 150 m of the start counts as the start
        var near = samples
        for i in 0..<12 where i >= 3 {
            let p = geo((x: 0, y: Double(i) * 35))
            near[i] = RoutePathSample(lat: p.lat, lon: p.lon, hAccM: 5, odometerKm: 100.0 + Double(i) * 0.035)
        }
        XCTAssertNotNil(TripBuilder.shape(near).start)
        // a bad fix (accuracy 60 m) is not used
        var bad = near
        bad[3] = RoutePathSample(lat: geo((x: 0, y: 105)).lat, lon: geo((x: 0, y: 105)).lon, hAccM: 60, odometerKm: 100.1)
        XCTAssertGreaterThan(Geo.distanceM(TripBuilder.shape(bad).start ?? GeoPoint(lat: 0, lon: 0), geo((x: 0, y: 105))), 5)
    }

    // MARK: Routes from trips

    func test_T63_firstTripWaits_secondTripSuggestsARoute() {
        let r = feed([ride("a", SyntheticRoutes.main, at: 0), ride("b", SyntheticRoutes.main, at: 24)])
        XCTAssertEqual(r.outcomes["a"], .pending)
        XCTAssertEqual(r.outcomes["b"], .suggested)
        XCTAssertEqual(r.book.routes.count, 1)
        XCTAssertEqual(r.book.routes[0].state, .suggested)
        XCTAssertEqual(r.book.places.count, 2)
        XCTAssertEqual(r.assigned["a"]?.routeId, r.book.routes[0].id)
        XCTAssertEqual(r.assigned["b"]?.routeId, r.book.routes[0].id)
        XCTAssertEqual(r.book.routes[0].sizeClass, "ride")
        XCTAssertEqual(r.book.routes[0].usualDistanceM, 3_742, accuracy: 5)
        XCTAssertEqual(r.book.variants.count, 1)
        XCTAssertTrue(r.book.variants[0].isReference)
        XCTAssertEqual(r.book.variants[0].name, "Variant 1")
    }

    func test_third_trip_joinsTheRoute_notANewSuggestion() {
        let r = feed([ride("a", SyntheticRoutes.main), ride("b", SyntheticRoutes.main, at: 24), ride("c", SyntheticRoutes.main, at: 48)])
        XCTAssertEqual(r.book.routes.count, 1)
        XCTAssertEqual(r.assigned["c"]?.routeId, r.book.routes[0].id)
        XCTAssertEqual(r.book.places.count, 2)
    }

    func test_parkedElsewhere_150mOffStart_stillMatchesTheRoute() {
        let moved = SyntheticRoutes.offset(SyntheticRoutes.main, by: (x: 120, y: 0))        // both ends 120 m away: within 187 m
        let r = feed([ride("a", SyntheticRoutes.main), ride("b", SyntheticRoutes.main, at: 24), ride("c", moved, at: 48)])
        XCTAssertEqual(r.book.routes.count, 1)
        XCTAssertEqual(r.assigned["c"]?.routeId, r.book.routes[0].id)
    }

    func test_tooFarApart_isAnotherTrip() {
        let far = SyntheticRoutes.offset(SyntheticRoutes.main, by: (x: 400, y: 0))
        let r = feed([ride("a", SyntheticRoutes.main), ride("b", far, at: 24)])
        XCTAssertEqual(r.outcomes["b"], .pending)
        XCTAssertTrue(r.book.routes.isEmpty)
    }

    func test_M11_loop_isNeverARoute() {
        let r = feed([ride("a", SyntheticRoutes.loop), ride("b", SyntheticRoutes.loop, at: 24), ride("c", SyntheticRoutes.loop, at: 48)])
        XCTAssertEqual(r.outcomes["a"], .loop)
        XCTAssertEqual(r.outcomes["b"], .loop)
        XCTAssertEqual(r.outcomes["c"], .loop)
        XCTAssertTrue(r.book.routes.isEmpty)
        XCTAssertTrue(r.book.places.isEmpty)
    }

    func test_noGpsAtAnEnd_andShortTrips_areNotMatched() {
        var book = RouteBook()
        var noStart = ride("n", SyntheticRoutes.main)
        noStart.shape.start = nil
        XCTAssertEqual(book.ingest(noStart, pool: []).assignments.first?.outcome, .noGps)
        var noEnd = ride("m", SyntheticRoutes.main)
        noEnd.shape.end = nil
        XCTAssertEqual(book.ingest(noEnd, pool: []).assignments.first?.outcome, .noGps)
        let short = ride("s", [(x: 0, y: 0), (x: 0, y: 400)])
        XCTAssertEqual(book.ingest(short, pool: []).assignments.first?.outcome, .tooShort)
        // a trip with no GPS at an end is no mate either
        let r = feed([noStart, ride("b", SyntheticRoutes.main, at: 24)])
        XCTAssertEqual(r.outcomes["b"], .pending)
    }

    func test_dismissedRoute_staysDismissed_andIsNotSuggestedAgain() {
        var r = feed([ride("a", SyntheticRoutes.main), ride("b", SyntheticRoutes.main, at: 24)])
        r.book.routes[0].state = .dismissed
        let update = r.book.ingest(ride("c", SyntheticRoutes.main, at: 48), pool: [], makeID: { "x" })
        XCTAssertEqual(update.assignments.first?.outcome, .dismissedRoute)
        XCTAssertNil(update.assignments.first?.routeId)
        XCTAssertTrue(update.newRoutes.isEmpty)
        // and a trip next to it does not make a second suggestion
        let d = r.book.ingest(ride("d", SyntheticRoutes.main, at: 72), pool: [ride("c", SyntheticRoutes.main, at: 48)], makeID: { "y" })
        XCTAssertTrue(d.newRoutes.isEmpty)
    }

    func test_savedRoute_reportsMatched() {
        var r = feed([ride("a", SyntheticRoutes.main), ride("b", SyntheticRoutes.main, at: 24)])
        r.book.routes[0].state = .saved
        let update = r.book.ingest(ride("c", SyntheticRoutes.main, at: 48), pool: [], makeID: { "z" })
        XCTAssertEqual(update.assignments.first?.outcome, .matched)
        XCTAssertEqual(update.assignments.first?.routeId, r.book.routes[0].id)
    }

    func test_thereAndBack_areTwoDirectionalRoutes() {
        let r = feed([ride("a", SyntheticRoutes.main), ride("b", SyntheticRoutes.reversed(SyntheticRoutes.main), at: 8),
                      ride("c", SyntheticRoutes.main, at: 24), ride("d", SyntheticRoutes.reversed(SyntheticRoutes.main), at: 32)])
        XCTAssertEqual(r.book.routes.count, 2)
        XCTAssertEqual(r.book.places.count, 2, "both routes share the two places")
        let ab = r.book.routes[0]
        let ba = r.book.routes[1]
        XCTAssertEqual(ab.fromPlaceId, ba.toPlaceId)
        XCTAssertEqual(ab.toPlaceId, ba.fromPlaceId)
        XCTAssertEqual(r.assigned["a"]?.routeId, ab.id)
        XCTAssertEqual(r.assigned["b"]?.routeId, ba.id)
        XCTAssertEqual(r.assigned["c"]?.routeId, ab.id)
        XCTAssertEqual(r.assigned["d"]?.routeId, ba.id)
    }

    func test_M11_routeUsesItsUsualDistanceForTheTolerance() {
        // a saved route of 20 km has a 1 km tolerance, so a trip starting 600 m from the place still matches it
        let from = PlaceInfo(id: "A", point: geo((x: 0, y: 0)))
        let to = PlaceInfo(id: "B", point: geo((x: 0, y: 20_000)))
        var book = RouteBook(places: [from, to], routes: [RouteInfo(id: "R", fromPlaceId: "A", toPlaceId: "B", usualDistanceM: 20_000, state: .saved)])
        let trip = ride("t", [(x: 0, y: 600), (x: 0, y: 20_000)])
        XCTAssertEqual(book.ingest(trip, pool: [], makeID: { "n" }).assignments.first?.routeId, "R")
        // the same offset on a 4 km route is too far
        var short = RouteBook(places: [from, PlaceInfo(id: "B", point: geo((x: 0, y: 4_000)))],
                              routes: [RouteInfo(id: "R", fromPlaceId: "A", toPlaceId: "B", usualDistanceM: 4_000, state: .saved)])
        let t2 = ride("t2", [(x: 0, y: 600), (x: 0, y: 4_000)])
        XCTAssertNil(short.ingest(t2, pool: [], makeID: { "n" }).assignments.first?.routeId)
    }

    // MARK: M12 variants

    func test_M12_sameWay_isTheSameVariant_evenWithJitter() {
        let jittered = SyntheticRoutes.main.enumerated().map { (i, p) in (x: p.x + Double(i % 2) * 12, y: p.y - Double(i % 3) * 8) }
        let r = feed([ride("a", SyntheticRoutes.main), ride("b", SyntheticRoutes.main, at: 24), ride("c", jittered, at: 48)])
        XCTAssertEqual(r.book.variants.count, 1)
        XCTAssertEqual(r.assigned["c"]?.variantId, r.book.variants[0].id)
    }

    func test_M12_detour_isANewVariant_andItsOwnRidesJoinIt() {
        let r = feed([ride("a", SyntheticRoutes.main), ride("b", SyntheticRoutes.main, at: 24),
                      ride("c", SyntheticRoutes.detour, at: 48), ride("d", SyntheticRoutes.detour, at: 72)])
        XCTAssertEqual(r.book.routes.count, 1)
        XCTAssertEqual(r.book.variants.count, 2)
        XCTAssertEqual(r.book.variants[1].name, "Variant 2")
        XCTAssertFalse(r.book.variants[1].isReference)
        XCTAssertNotEqual(r.assigned["c"]?.variantId, r.assigned["a"]?.variantId)
        XCTAssertEqual(r.assigned["d"]?.variantId, r.assigned["c"]?.variantId)
    }

    func test_M12_zigzagThatKeepsCrossingBack_isNoNewVariant() {
        // the usual way with a 60 m zigzag every 30 m: out of the 50 m corridor only every other point
        var zig: [GeoPoint] = []
        let base = shape(SyntheticRoutes.main).path
        for (i, p) in base.enumerated() {
            let off = (i / 2) % 2 == 0 ? 0.0 : 80.0                            // 20 m in, 20 m out
            zig.append(GeoPoint(lat: p.lat, lon: p.lon + off / (Geo.mPerDegLat * cos(10 * Double.pi / 180))))
        }
        let sections = VariantMatcher.offPathSections(zig, from: base, routeLengthM: 3_742)
        XCTAssertTrue(sections.isEmpty, "the zigzag crosses back every 20 m: \(sections)")
    }

    func test_M12_detourSection_isMeasured() {
        let main = shape(SyntheticRoutes.main).path
        let det = shape(SyntheticRoutes.detour).path
        let sections = VariantMatcher.offPathSections(det, from: main, routeLengthM: 3_742)
        XCTAssertEqual(sections.count, 1)
        XCTAssertGreaterThan(sections[0].lengthM, 1_000)
        XCTAssertGreaterThanOrEqual(sections[0].offShare, 0.8)
        XCTAssertLessThan(VariantMatcher.coverage(det, on: main, routeLengthM: 3_742), 0.6)
    }

    func test_M12_shortOffPath_under5PercentOfTheRoute_isNotAVariant() {
        // a 140 m side step in the middle of a 3.7 km route (5% = 187 m)
        let wobble: [XY] = [(0, 0), (0, 700), (600, 1100), (640, 1100), (640, 1190), (690, 1190), (690, 1100), (1400, 1100), (1400, 1900), (2000, 2300)]
        let sections = VariantMatcher.offPathSections(shape(wobble).path, from: shape(SyntheticRoutes.main).path, routeLengthM: 3_742)
        XCTAssertTrue(sections.isEmpty)
    }

    func test_M12_differentParkingSpot_atTheEnds_isNotAVariant() {
        // starts 140 m west of the usual start and walks onto the route: the first 150 m are inside the end zone
        let other: [XY] = [(-140, 0), (0, 0)] + Array(SyntheticRoutes.main.dropFirst())
        let r = feed([ride("a", SyntheticRoutes.main), ride("b", SyntheticRoutes.main, at: 24), ride("c", other, at: 48)])
        XCTAssertEqual(r.book.variants.count, 1)
        XCTAssertEqual(r.book.routes.count, 1)
    }

    func test_M12_classify_prefersTheBestVariant() {
        let a = VariantInfo(id: "a", routeId: "R", name: "Variant 1", path: shape(SyntheticRoutes.main).path, isReference: true)
        let b = VariantInfo(id: "b", routeId: "R", name: "Variant 2", path: shape(SyntheticRoutes.detour).path)
        XCTAssertEqual(VariantMatcher.classify(shape(SyntheticRoutes.detour).path, variants: [a, b], routeLengthM: 4_000), .same(variantId: "b"))
        XCTAssertEqual(VariantMatcher.classify(shape(SyntheticRoutes.main).path, variants: [a, b], routeLengthM: 4_000), .same(variantId: "a"))
        XCTAssertEqual(VariantMatcher.classify(shape(SyntheticRoutes.detour).path, variants: [a], routeLengthM: 4_000), .new)
    }

    func test_M12_medoid_isTheMiddleOne() {
        let base = shape(SyntheticRoutes.main).path
        func shifted(_ m: Double) -> [GeoPoint] {
            base.map { GeoPoint(lat: $0.lat, lon: $0.lon + m / (Geo.mPerDegLat * cos(10 * Double.pi / 180))) }
        }
        XCTAssertEqual(VariantMatcher.medoidIndex(of: [shifted(0), shifted(10), shifted(30)]), 1)
        XCTAssertEqual(VariantMatcher.medoidIndex(of: [shifted(0)]), 0)
        XCTAssertNil(VariantMatcher.medoidIndex(of: []))
    }

    func test_distinguishingPoints_areTheOffPathPart() {
        let main = shape(SyntheticRoutes.main).path
        let det = shape(SyntheticRoutes.detour).path
        let part = VariantMatcher.distinguishingPoints(of: det, against: main, routeLengthM: 3_742)
        XCTAssertLessThan(part.count, det.count)
        XCTAssertGreaterThan(Geo.pathLengthM(part), 1_000)
        XCTAssertEqual(VariantMatcher.distinguishingPoints(of: main, against: main, routeLengthM: 3_742).count, main.count)
    }

    // MARK: Street names

    func test_streetNaming_longestWins_andFallbacks() {
        XCTAssertEqual(StreetNaming.longest(["Herzl", nil, "Ibn Gabirol", "Ibn Gabirol", ""]), "Ibn Gabirol")
        XCTAssertEqual(StreetNaming.longest(["A", "B"]), "A", "a tie goes to the first")
        XCTAssertNil(StreetNaming.longest([nil, nil]))
        XCTAssertEqual(StreetNaming.variantName(street: "Ibn Gabirol", fallbackIndex: 2), "via Ibn Gabirol")
        XCTAssertEqual(StreetNaming.variantName(street: nil, fallbackIndex: 2), "Variant 2")
        let v = VariantInfo(id: "v", routeId: "R", name: "Variant 2", path: [])
        XCTAssertTrue(v.hasFallbackName)
        var byHand = v
        byHand.name = "Variant 2"
        byHand.nameByHand = true
        XCTAssertFalse(byHand.hasFallbackName, "a name typed by hand is never replaced")
        var named = v
        named.name = "via Herzl"
        XCTAssertFalse(named.hasFallbackName)
    }

    func test_streetNaming_samplesAtMost5PointsRoundedTo100m() {
        let path = shape(SyntheticRoutes.main).path
        let pts = StreetNaming.samplePoints(path)
        XCTAssertEqual(pts.count, 5)
        for p in pts {
            XCTAssertEqual(p.lat * 1000, (p.lat * 1000).rounded(), accuracy: 0.0001)
            XCTAssertEqual(p.lon * 1000, (p.lon * 1000).rounded(), accuracy: 0.0001)
        }
        XCTAssertEqual(StreetNaming.samplePoints(Array(path.prefix(3))).count, 3)
        XCTAssertEqual(StreetNaming.cacheKey(GeoPoint(lat: 10.00049, lon: -29.99951)), "geo.10.000.-30.000")
    }

    // MARK: Synthetic scenarios through the real engine

    /// The scenario through the Recorder's pure part: one `RoutedRide` per closed ride (the app's Recorder does the same, then ingests).
    private func ridesOf(_ stream: SimStream) -> [RoutedRide] {
        var core = RideRecorderCore()
        var samples: [Int: [RecorderSample]] = [:]
        var closes: [RecorderClose] = []
        RecorderRunner.play(RecorderRunner.inputs(stream), core: &core) { a in
            switch a {
            case let .samples(seq, list): samples[seq, default: []] += list
            case let .rideEnded(c): closes.append(c)
            case let .rideCancelled(seq): samples[seq] = nil
            default: break
            }
        }
        var out: [RoutedRide] = []
        for (i, c) in closes.enumerated() {
            let list = (samples[c.end.ride.seq] ?? []).map { $0.sample }
            let m = c.end.metrics(list, ignoredReadings: c.ignoredReadings)
            let path = list.map { RoutePathSample(lat: $0.lat, lon: $0.lon, hAccM: $0.hAccM, odometerKm: $0.odometerKm) }
            out.append(RoutedRide(id: "r\(i)", startAt: Int64(c.end.ride.startT * 1000), distanceM: m.distanceM, shape: TripBuilder.shape(path)))
        }
        return out
    }

    func test_scenario_commute3_throughTheEngine_givesOneSuggestedRoute() throws {
        let rides = ridesOf(try XCTUnwrap(SyntheticScenario.all.first { $0.id == "ROUTE-COMMUTE" }).build())
        XCTAssertEqual(rides.count, 3)
        for r in rides {
            XCTAssertEqual(r.distanceM, 3_742, accuracy: 300)
            XCTAssertNotNil(r.shape.start)
            XCTAssertNotNil(r.shape.end)
        }
        let r = feed(rides)
        XCTAssertEqual(r.outcomes["r0"], .pending)
        XCTAssertEqual(r.outcomes["r1"], .suggested)
        XCTAssertEqual(r.outcomes["r2"], .suggested)
        XCTAssertEqual(r.book.routes.count, 1)
        XCTAssertEqual(r.book.variants.count, 1, "three jittery runs of the same way are one variant")
        XCTAssertEqual(r.assigned.count, 3)
    }

    func test_scenario_variant_throughTheEngine_givesTwoVariants() throws {
        let r = feed(ridesOf(try XCTUnwrap(SyntheticScenario.all.first { $0.id == "ROUTE-VARIANT" }).build()))
        XCTAssertEqual(r.book.routes.count, 1)
        XCTAssertEqual(r.book.variants.count, 2)
        XCTAssertEqual(r.book.variants.filter { $0.isReference }.count, 1)
    }

    func test_scenario_thereAndBack_throughTheEngine_givesTwoRoutes() throws {
        let r = feed(ridesOf(try XCTUnwrap(SyntheticScenario.all.first { $0.id == "ROUTE-THEREBACK" }).build()))
        XCTAssertEqual(r.book.routes.count, 2)
        XCTAssertEqual(r.book.places.count, 2)
    }

    func test_scenario_loop_throughTheEngine_givesNoRoute() throws {
        let rides = ridesOf(try XCTUnwrap(SyntheticScenario.all.first { $0.id == "ROUTE-LOOP" }).build())
        XCTAssertEqual(rides.count, 2)
        let r = feed(rides)
        XCTAssertTrue(r.book.routes.isEmpty)
        XCTAssertEqual(r.outcomes["r0"], .loop)
    }

    func test_scenario_noGpsAtTheStart_isNotMatched() throws {
        let rides = ridesOf(try XCTUnwrap(SyntheticScenario.all.first { $0.id == "ROUTE-NOGPS" }).build())
        XCTAssertEqual(rides.count, 2)
        XCTAssertNotNil(rides[0].shape.start)
        XCTAssertNil(rides[1].shape.start, "the second trip had no GPS for its first 150 s")
        let r = feed(rides)
        XCTAssertEqual(r.outcomes["r1"], .noGps)
        XCTAssertTrue(r.book.routes.isEmpty)
    }

    func test_scenario_gpsLoss_keepsTheRideAndItsEnds() throws {
        let rides = ridesOf(try XCTUnwrap(SyntheticScenario.all.first { $0.id == "ROUTE-GPSLOSS" }).build())
        XCTAssertEqual(rides.count, 4)
        let r = feed(rides)
        XCTAssertEqual(r.book.routes.count, 1)
        XCTAssertEqual(r.assigned["r3"]?.routeId, r.book.routes[0].id, "GPS lost half way: both ends are known, so it still matches")
        XCTAssertTrue(rides[3].shape.hasGap)
        XCTAssertFalse(rides[0].shape.hasGap)
        XCTAssertEqual(r.book.variants.count, 1, "a ride with a GPS gap never creates a variant")
    }
}
