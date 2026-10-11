import XCTest
@testable import CorckieCore

/// M5-01 / M5-02: compare rows and suggestions, the merge offer rule, merge and trim numbers.
final class RideToolsTests: XCTestCase {
    // MARK: Helpers

    /// A made-up ride: `n` samples 5 s apart at 18 km/h, odometer +0.025 km per sample, 216 W, battery 80% falling 1 point per 20 samples.
    private func ride(startT: Double = 0, odoStartKm: Double = 100, n: Int = 100, lat: Double = 10, lon: Double = 20,
                      batteryStart: Int = 80) -> [RideSample] {
        var out: [RideSample] = []
        for i in 0..<n {
            let step = Double(i)
            let t: Double = startT + step * 5
            let la: Double = lat + step * 0.000_2
            let alt: Double = 50 + step * 0.1
            let odo: Double = odoStartKm + step * 0.025
            let pct: Int = batteryStart - i / 20
            out.append(RideSample(t: t, speedKmh: 18, gpsSpeedKmh: 18, lat: la, lon: lon, hAccM: 5, altBaroM: alt,
                                  voltage: 54, currentA: 4, batteryPct: pct, tempC: 30, odometerKm: odo))
        }
        return out
    }

    private func compareRide(_ id: String, route: String? = nil, variant: String? = nil, start: Int64 = 0, dist: Double = 5_000,
                             total: Double = 1_200, used: Double = 10, sim: Bool = false,
                             from: (Double, Double)? = nil, to: (Double, Double)? = nil) -> CompareRide {
        CompareRide(id: id, title: id, startAt: start, routeId: route, variantId: variant, distanceM: dist, totalS: total,
                    movingS: total - 60, avgMovingMps: dist / total, topSpeedMps: 8, usedPct: used, elevGainM: 20, energyWhRaw: 90,
                    startLat: from?.0, startLon: from?.1, endLat: to?.0, endLon: to?.1, isSimulated: sim)
    }

    // MARK: Compare

    func testCompareRowsShowBothValuesAndPlainDifference() {
        let a = compareRide("a", total: 1_270, used: 12)
        let b = compareRide("b", total: 1_200, used: 10)
        let rows = RideCompareBuilder.rows(a, b)
        XCTAssertEqual(rows.map(\.label), ["Time", "Moving time", "Distance", "Avg. speed", "Top speed", "Battery used", "Battery per km", "Climbed", "Energy"])
        let time = rows[0]
        XCTAssertEqual(time.a, "21 min")
        XCTAssertEqual(time.b, "20 min")
        XCTAssertEqual(time.difference, "+1 min 10 s")
        XCTAssertEqual(rows[2].difference, "same")
        XCTAssertEqual(rows[5].difference, "+2 points")
        XCTAssertEqual(rows[6].a, "2.4%")
    }

    func testCompareMissingValueGivesDash() {
        let a = compareRide("a")
        var b = compareRide("b")
        b.usedPct = nil
        b.energyWhRaw = nil
        let rows = RideCompareBuilder.rows(a, b)
        XCTAssertEqual(rows[5].b, "\u{2013}")
        XCTAssertEqual(rows[5].difference, "\u{2013}")
        XCTAssertEqual(rows[8].difference, "\u{2013}")
    }

    func testCompareNoRewardWords() {
        let rows = RideCompareBuilder.rows(compareRide("a", total: 900), compareRide("b", total: 1_200))
        let text = rows.map { $0.label + $0.a + $0.b + $0.difference }.joined().lowercased()
        for word in ["better", "worse", "record", "best", "beat", "faster than", "congrat"] { XCTAssertFalse(text.contains(word)) }
        XCTAssertEqual(rows[0].difference, "\u{2212}5 min 00 s")
    }

    func testRelationWords() {
        XCTAssertEqual(RideCompareBuilder.relation(compareRide("a", route: "r", variant: "v"), compareRide("b", route: "r", variant: "v")), "Same route, same variant")
        XCTAssertEqual(RideCompareBuilder.relation(compareRide("a", route: "r", variant: "v"), compareRide("b", route: "r", variant: "w")), "Same route")
        XCTAssertEqual(RideCompareBuilder.relation(compareRide("a"), compareRide("b")), "Different trips")
    }

    func testSuggestionsSameRouteSameVariantFirstThenNewest() {
        let me = compareRide("me", route: "r", variant: "v", start: 100)
        let all = [me,
                   compareRide("old-v", route: "r", variant: "v", start: 10),
                   compareRide("new-w", route: "r", variant: "w", start: 90),
                   compareRide("other-route", route: "x", variant: "v", start: 95),
                   compareRide("sim", route: "r", variant: "v", start: 99, sim: true),
                   compareRide("mid-w", route: "r", variant: "w", start: 50)]
        let ids = RideCompareBuilder.suggestions(for: me, among: all).map(\.id)
        XCTAssertEqual(ids, ["old-v", "new-w", "mid-w"])
        XCTAssertEqual(RideCompareBuilder.suggestions(for: me, among: all, limit: 2).count, 2)
    }

    func testSuggestionsWithoutRouteUseTheEndsAndDistance() {
        let a = (10.0, 20.0), b = (10.01, 20.0)
        let me = compareRide("me", start: 100, dist: 5_000, from: a, to: b)
        let near = compareRide("near", start: 50, dist: 5_400, from: (10.000_5, 20.0), to: b)
        let farStart = compareRide("far", start: 60, dist: 5_000, from: (10.1, 20.0), to: b)
        let longer = compareRide("long", start: 70, dist: 9_000, from: a, to: b)
        let ids = RideCompareBuilder.suggestions(for: me, among: [me, near, farStart, longer]).map(\.id)
        XCTAssertEqual(ids, ["near"])
        XCTAssertEqual(RideCompareBuilder.relation(me, near), "Similar start and end")
    }

    // MARK: Merge offer

    private func end(_ id: String, start: Int64, end: Int64?, from: (Double, Double)? = nil, to: (Double, Double)? = nil,
                     sim: Bool = false, kind: String = "ride") -> MergeEnd {
        MergeEnd(id: id, startAt: start, endAt: end, startLat: from?.0, startLon: from?.1, endLat: to?.0, endLon: to?.1, isSimulated: sim, kind: kind)
    }

    func testMergeOfferRule30MinAnd200M() {
        let prev = end("a", start: 0, end: 1_000_000, to: (10, 20))
        func next(gapS: Double, northM: Double) -> MergeEnd {
            end("b", start: 1_000_000 + Int64(gapS * 1000), end: 2_000_000, from: (10 + northM / 111_195, 20))
        }
        XCTAssertNotNil(RideMerge.offer(previous: prev, next: next(gapS: 1_800, northM: 190)))
        XCTAssertNil(RideMerge.offer(previous: prev, next: next(gapS: 1_801, northM: 100)))
        XCTAssertNil(RideMerge.offer(previous: prev, next: next(gapS: 600, northM: 215)))
        let offer = RideMerge.offer(previous: prev, next: next(gapS: 720, northM: 80))
        XCTAssertEqual(offer?.gapS, 720)
        XCTAssertEqual(Int(offer?.gapM.rounded() ?? 0), 80)
        XCTAssertEqual(offer?.text, "Stopped 12 min, 80 m from where this ride started")
    }

    func testMergeOfferNeedsPlacesRealWithRealAndNoOverlap() {
        let prev = end("a", start: 0, end: 1_000_000, to: (10, 20))
        XCTAssertNil(RideMerge.offer(previous: prev, next: end("b", start: 1_100_000, end: nil)))                                    // no start place
        XCTAssertNil(RideMerge.offer(previous: prev, next: end("b", start: 900_000, end: 2_000_000, from: (10, 20))))                // overlaps
        XCTAssertNil(RideMerge.offer(previous: prev, next: end("b", start: 1_100_000, end: 2_000_000, from: (10, 20), sim: true)))   // real with simulated
        XCTAssertNil(RideMerge.offer(previous: prev, next: end("b", start: 1_100_000, end: 2_000_000, from: (10, 20), kind: "discarded")))
        XCTAssertNil(RideMerge.offer(previous: end("a", start: 0, end: nil, to: (10, 20)), next: end("b", start: 1_100_000, end: 2_000_000, from: (10, 20))))
        XCTAssertEqual(RideMerge.shiftMs(firstStartAt: 1_000, secondStartAt: 1_501_000), 1_500_000)
    }

    // MARK: Merge numbers

    func testMergedNumbersAddUpAndThePauseIsNotAGap() {
        let a = ride(odoStartKm: 100, n: 100)                        // 0 ... 495 s, 100.000 ... 102.475 km
        let b = ride(startT: 1_095, odoStartKm: 102.475, n: 100)     // 10 min pause, then 1095 ... 1590 s
        let bridge = RideStopSpan(startT: 495, endT: 1_095)
        let alone = RideRecompute.metrics(samples: a, stops: [], walks: [])
        let merged = RideRecompute.metrics(samples: a + b, stops: [bridge], walks: [], bridges: [bridge])
        XCTAssertEqual(alone.distanceM, 2_475, accuracy: 1)
        XCTAssertEqual(merged.distanceM, 4_950, accuracy: 1)
        XCTAssertEqual(merged.stops, 1)
        XCTAssertEqual(merged.totalS, 1_590, accuracy: 0.5)
        XCTAssertEqual(merged.movingS, 990, accuracy: 0.5)
        XCTAssertEqual(merged.gapScooterS, 0, accuracy: 0.5)
        XCTAssertEqual(merged.odoStartKm ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(merged.odoEndKm ?? 0, 102.475 + 2.475, accuracy: 0.001)
        // without telling the metrics about the bridge the pause would count as missing scooter data
        let naive = RideRecompute.metrics(samples: a + b, stops: [bridge], walks: [])
        XCTAssertEqual(naive.gapScooterS, 600, accuracy: 0.5)
    }

    // MARK: Trim

    func testTrimRecomputesNumbersFromTheWindow() {
        let all = ride(n: 100)                                       // 0 ... 495 s
        let full = RideRecompute.metrics(samples: all, stops: [], walks: [])
        let cut = RideRecompute.metrics(samples: all, stops: [], walks: [], trimStartS: 100, trimEndS: 300)
        XCTAssertEqual(full.distanceM, 2_475, accuracy: 1)
        XCTAssertEqual(cut.distanceM, 1_000, accuracy: 1)
        XCTAssertEqual(cut.totalS, 200, accuracy: 0.5)
        XCTAssertEqual(cut.movingS, 200, accuracy: 0.5)
        XCTAssertEqual(cut.energyWhRaw, 216.0 * 200 / 3600, accuracy: 0.5)
        // a window that does not start on a sample keeps the sample before it only as the odometer anchor
        let off = RideRecompute.metrics(samples: all, stops: [], walks: [], trimStartS: 102, trimEndS: 300)
        XCTAssertEqual(off.totalS, 198, accuracy: 5.1)
        XCTAssertLessThan(off.totalS, 200)
        // resetting = computing again without the window gives the full numbers
        XCTAssertEqual(RideRecompute.metrics(samples: all, stops: [], walks: []).distanceM, full.distanceM)
    }

    func testTrimClampKeepsAtLeastAMinute() {
        let c1 = RideTrim.clamp(startS: 10, endS: 400, lastS: 500)
        XCTAssertEqual(c1?.start, 10)
        XCTAssertEqual(c1?.end, 400)
        let c2 = RideTrim.clamp(startS: 440, endS: 450, lastS: 500)
        XCTAssertEqual(c2.map { $0.end - $0.start }, 60)
        let c3 = RideTrim.clamp(startS: -20, endS: 900, lastS: 500)
        XCTAssertEqual(c3?.start, 0)
        XCTAssertEqual(c3?.end, 500)
        XCTAssertNil(RideTrim.clamp(startS: 0, endS: 30, lastS: 40))
    }

    func testTrimClipsStopsAndDropsOnesOutside() {
        let stops = [RideStopSpan(startT: 10, endT: 40), RideStopSpan(startT: 90, endT: 130), RideStopSpan(startT: 400, endT: nil)]
        let clipped = RideTrim.clip(stops, startS: 100, endS: 300)
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(clipped[0].startT, 100)
        XCTAssertEqual(clipped[0].endT, 130)
        let m = RideRecompute.metrics(samples: ride(n: 100), stops: stops, walks: [], trimStartS: 100, trimEndS: 300)
        XCTAssertEqual(m.stops, 1)
    }
}
