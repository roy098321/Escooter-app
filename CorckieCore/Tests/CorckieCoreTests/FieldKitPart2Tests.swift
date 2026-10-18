import XCTest
@testable import CorckieCore
@testable import CorckieSim

/// T-00 part 2: the prediction log (settling + accuracy), shadow thresholds, the scenario list and the live ETA marks.
final class FieldKitPart2Tests: XCTestCase {
    // MARK: Accuracy

    func test_accuracy_medianAndP90_andTargetMet() {
        let errorsS: [Double] = [30, 60, 60, 120, 180]
        let rows = errorsS.enumerated().map { PredictionRow(kind: PredictionKind.time, predicted: 600 + $1, actual: 600, madeAt: Int64($0)) }
        let line = AccuracyCalc.lines(rows).first { $0.kind == PredictionKind.time }!
        XCTAssertEqual(line.n, 5)
        XCTAssertEqual(line.median ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(line.p90 ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(line.verdict, .met)
        XCTAssertEqual(line.question, "Q-C")
    }

    func test_accuracy_fewRides_cannotJudge_andEmptyIsNoData() {
        let rows = [PredictionRow(kind: PredictionKind.battery, predicted: 10, actual: 20, madeAt: 1)]
        let lines = AccuracyCalc.lines(rows)
        XCTAssertEqual(lines.first { $0.kind == PredictionKind.battery }?.verdict, .tooFew)
        XCTAssertEqual(lines.first { $0.kind == PredictionKind.range }?.verdict, .noData)
        XCTAssertEqual(lines.first { $0.kind == PredictionKind.eta25 }?.verdict, .noData)
        XCTAssertEqual(lines.count, 8)
    }

    func test_accuracy_notMetWhenMedianTooBig() {
        let rows = (0..<6).map { PredictionRow(kind: PredictionKind.battery, predicted: 10, actual: 16, madeAt: Int64($0)) }
        XCTAssertEqual(AccuracyCalc.lines(rows).first { $0.kind == PredictionKind.battery }?.verdict, .notYet)
    }

    func test_accuracy_calibrationSkipsTheFirstFiveRides() {
        var rows = (0..<5).map { PredictionRow(kind: PredictionKind.calib, predicted: 4, actual: 8, madeAt: Int64($0)) }
        rows.append(PredictionRow(kind: PredictionKind.calib, predicted: 8, actual: 8.4, madeAt: 10))
        rows.append(PredictionRow(kind: PredictionKind.calib, predicted: 8, actual: 8.4, madeAt: 11))
        let line = AccuracyCalc.lines(rows).first { $0.kind == PredictionKind.calib }!
        XCTAssertEqual(line.n, 2)
        XCTAssertEqual(line.median ?? 0, 0.4 / 8.4 * 100, accuracy: 1e-9)
    }

    func test_accuracy_errorUnits() {
        XCTAssertEqual(AccuracyCalc.error(kind: PredictionKind.eta50, predicted: 1_000_000, actual: 1_090_000) ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(AccuracyCalc.error(kind: PredictionKind.range, predicted: 22, actual: 20) ?? 0, 10, accuracy: 1e-9)
        XCTAssertNil(AccuracyCalc.error(kind: PredictionKind.range, predicted: 22, actual: 0))
        XCTAssertNil(AccuracyCalc.error(kind: "other", predicted: 1, actual: 1))
    }

    func test_accuracyText_hasQuestionNTargetAndOpenCount() {
        let rows = [PredictionRow(kind: PredictionKind.time, predicted: 600, actual: 640, madeAt: 1),
                    PredictionRow(kind: PredictionKind.time, predicted: 600, actual: nil, madeAt: 2)]
        let text = AccuracyCalc.text(rows, now: "today")
        XCTAssertTrue(text.contains("Q-C Today's time estimate"))
        XCTAssertTrue(text.contains("based on 1 ride "))
        XCTAssertTrue(text.contains("target: median error \u{2264} 1.5 min"))
        XCTAssertTrue(text.contains("1 settled, 1 waiting for a ride"))
    }

    // MARK: Settling

    private let start: Int64 = 1_800_000_000_000

    private func ride() -> SettledRide {
        SettledRide(id: "r", routeId: "A", startAt: start, endAt: start + 900_000, lastMoveAt: start + 870_000, totalS: 900, distanceM: 5_000,
                    usedPct: 12, startRestPct: 80, endRestPct: 70, energyWhRaw: 100)
    }

    func test_settle_matchesByRouteAndTime_newestPerKind_andComputesActuals() {
        let open = [
            OpenPrediction(id: 1, kind: PredictionKind.time, routeId: "A", madeAt: start - 3_600_000, predicted: 840),
            OpenPrediction(id: 2, kind: PredictionKind.time, routeId: "A", madeAt: start - 600_000, predicted: 870),
            OpenPrediction(id: 3, kind: PredictionKind.time, routeId: "B", madeAt: start - 600_000, predicted: 500),
            OpenPrediction(id: 4, kind: PredictionKind.battery, routeId: "A", madeAt: start - 1_000, predicted: 9),
            OpenPrediction(id: 5, kind: PredictionKind.eta50, routeId: "A", madeAt: start + 400_000, predicted: 1),
            OpenPrediction(id: 6, kind: PredictionKind.range, routeId: nil, madeAt: start + 10_000, predicted: 20, aux: 75),
            OpenPrediction(id: 7, kind: PredictionKind.calib, routeId: nil, madeAt: start + 10_000, predicted: 8),
            OpenPrediction(id: 8, kind: PredictionKind.time, routeId: "A", madeAt: start - 7 * 3_600_000, predicted: 700),
            OpenPrediction(id: 9, kind: PredictionKind.thereBack, routeId: "A", madeAt: start - 5_000, predicted: 66)
        ]
        let result = PredictionSettler.settle(open: open, ride: ride())
        XCTAssertEqual(result.settled.map(\.predictionId), [2, 4, 5, 6, 7, 9])
        func actual(_ id: Int64) -> Double { result.settled.first { $0.predictionId == id }?.actual ?? -1 }
        XCTAssertEqual(actual(2), 900)
        XCTAssertEqual(actual(4), 10)
        XCTAssertEqual(actual(5), Double(start + 870_000))
        XCTAssertEqual(actual(6), 75 * 5.0 / 10.0, accuracy: 1e-9)
        XCTAssertEqual(actual(7), 10, accuracy: 1e-9)
        XCTAssertEqual(actual(9), 70)
        XCTAssertEqual(result.dropIds, [1])
    }

    func test_settle_batteryFallsBackToUsedPct_andShortRangeIsDropped() {
        var r = ride()
        r.startRestPct = nil
        r.endRestPct = nil
        r.usedPct = 3
        r.distanceM = 800
        let open = [OpenPrediction(id: 1, kind: PredictionKind.battery, routeId: "A", madeAt: start - 1_000, predicted: 4),
                    OpenPrediction(id: 2, kind: PredictionKind.range, routeId: nil, madeAt: start + 1_000, predicted: 20, aux: 70),
                    OpenPrediction(id: 3, kind: PredictionKind.thereBack, routeId: "A", madeAt: start - 1_000, predicted: 60)]
        let result = PredictionSettler.settle(open: open, ride: r)
        XCTAssertEqual(result.settled.map(\.predictionId), [1])
        XCTAssertEqual(result.settled.first?.actual, 3)
        XCTAssertEqual(result.dropIds, [2, 3])
    }

    func test_settle_ignoresPredictionsOfOtherTimes() {
        let open = [OpenPrediction(id: 1, kind: PredictionKind.range, routeId: nil, madeAt: start - 3_600_000, predicted: 20, aux: 70),
                    OpenPrediction(id: 2, kind: PredictionKind.eta25, routeId: nil, madeAt: start + 2_000_000, predicted: 5)]
        let result = PredictionSettler.settle(open: open, ride: ride())
        XCTAssertTrue(result.settled.isEmpty)
        XCTAssertTrue(result.dropIds.isEmpty)
    }

    // MARK: Shadow

    private func samples(_ speeds: [Double], scooter: Bool = true) -> [ShadowSample] {
        speeds.enumerated().map { ShadowSample(t: Double($0) * 5, scooter: scooter, scooterKmh: $1, gpsKmh: $1) }
    }

    func test_shadow_end_longerWaitsWouldStillBeOpen() {
        let speeds = Array(repeating: 20.0, count: 21) + Array(repeating: 0.0, count: 8)      // moving to t=100, still to t=135
        let d = ShadowCalc.end(samples(speeds))
        XCTAssertEqual(d.map(\.variant), ["30 s", "60 s", "90 s"])
        XCTAssertEqual(d.map(\.differs), [false, true, true])
        XCTAssertEqual(d[0].decision, "ends 30 s after the last movement")
        XCTAssertTrue(d[1].decision.hasPrefix("still open"))
        XCTAssertTrue(d[0].isStandard)
    }

    func test_shadow_autostart_higherLimitsStartLater() {
        let d = ShadowCalc.autostart(samples([0, 2.5, 3.5, 5, 20]))
        XCTAssertEqual(d.map(\.differs), [false, true, true])
        XCTAssertTrue(d[0].decision.contains("+5 s"))
        XCTAssertTrue(d[2].decision.contains("+15 s"))
    }

    func test_shadow_slow_48Standard_45And51Kept() {
        let d = ShadowCalc.slow(samples([40, 49, 47, 45, 50, 42, 46]))
        XCTAssertEqual(d.map(\.variant), ["48 km/h", "45 km/h", "51 km/h"])
        XCTAssertEqual(d.map(\.isStandard), [true, false, false])
        XCTAssertEqual(d[0].decision, "2 warnings")
        XCTAssertEqual(d[1].decision, "2 warnings", "45: on at 49, clears at 42, on at 46")
        XCTAssertEqual(d[2].decision, "0 warnings")
        XCTAssertFalse(d[0].differs)
        XCTAssertFalse(d[1].differs)
        XCTAssertTrue(d[2].differs)
    }

    func test_shadow_different_90sWouldHaveCalledItUsual() {
        let d = ShadowCalc.different(thisTotalS: 700, thisUsedPct: nil, otherTotalS: [600, 610, 620, 630], otherUsedPct: [])
        XCTAssertEqual(d.map(\.decision), ["noticeably different", "noticeably different", "usual"])
        XCTAssertEqual(d.map(\.differs), [false, false, true])
        XCTAssertTrue(ShadowCalc.different(thisTotalS: 700, thisUsedPct: nil, otherTotalS: [600, 610], otherUsedPct: []).isEmpty)
    }

    func test_shadow_gates_openOrClosedPerValue() {
        let d = ShadowCalc.gates(timedRides: 3, batteryRides: 4, trips: 2)
        func differs(_ rule: String) -> [Bool] { d.filter { $0.rule == rule }.map(\.differs) }
        XCTAssertEqual(differs(ShadowCalc.ruleGateTime), [false, false, true])       // 3 (standard), 2, 4
        XCTAssertEqual(differs(ShadowCalc.ruleGateBattery), [false, true, false])    // 5 (standard), 4, 6
        XCTAssertEqual(differs(ShadowCalc.ruleGateRoute), [false, false, true])      // 2 (standard), 1, 3
    }

    func test_shadow_evaluate_withoutARoute_hasNoRouteRules() {
        let d = ShadowCalc.evaluate(samples: samples([0, 5, 20, 20, 0, 0]), thisTotalS: 600, thisUsedPct: 8, route: nil)
        XCTAssertFalse(d.contains { $0.rule == ShadowCalc.ruleDifferent || $0.rule.hasPrefix("gate.") })
        XCTAssertTrue(d.contains { $0.rule == ShadowCalc.ruleEnd })
        let withRoute = ShadowCalc.evaluate(samples: samples([0, 5, 20]), thisTotalS: 600, thisUsedPct: 8,
                                            route: ShadowCalc.RouteHistory(otherTotalS: [590, 600, 610], otherUsedPct: []))
        XCTAssertTrue(withRoute.contains { $0.rule == ShadowCalc.ruleDifferent })
        XCTAssertTrue(withRoute.contains { $0.rule == ShadowCalc.ruleGateTime })
    }

    func test_shadow_text_countsDifferences() {
        let rows = [ShadowRow(startAt: start, rule: ShadowCalc.ruleSlow, variant: "45 km/h", decision: "2 warnings", differs: false, isStandard: true),
                    ShadowRow(startAt: start, rule: ShadowCalc.ruleSlow, variant: "48 km/h", decision: "0 warnings", differs: true, isStandard: false),
                    ShadowRow(startAt: start + 1, rule: ShadowCalc.ruleSlow, variant: "45 km/h", decision: "1 warning", differs: false, isStandard: true),
                    ShadowRow(startAt: start + 1, rule: ShadowCalc.ruleSlow, variant: "48 km/h", decision: "1 warning", differs: false, isStandard: false)]
        let text = ShadowCalc.text(rows, now: "today")
        XCTAssertTrue(text.contains("45 km/h (standard): 2 rides"))
        XCTAssertTrue(text.contains("48 km/h: 2 rides, decided differently in 1"))
        XCTAssertTrue(text.contains("0 warnings"))
        XCTAssertTrue(text.contains("no rides yet"))          // the other rules have no rows
    }

    // MARK: Scenarios

    private let base: Int64 = 1_760_000_000_000       // 08:53 UTC

    private func plain(_ id: String = "r1", offset: Int = 0) -> ScenarioRide {
        ScenarioRide(id: id, startAtMs: base, endAtMs: base + 600_000, utcOffsetMin: offset, totalS: 600, distanceM: 3_000, startPct: 80,
                     wet: "dry", gapGpsS: 0, hasGps: true, loadKg: nil, loadLevel: nil, firstOnItsRoute: false)
    }

    private func ids(_ rides: [ScenarioRide], _ marks: ScenarioMarks = ScenarioMarks()) -> Set<String> {
        Set(ScenarioRules.evaluate(rides, marks: marks).map(\.id))
    }

    func test_scenarios_aPlainDaytimeRideTicksNothing() {
        XCTAssertEqual(ids([plain()]), [])
    }

    func test_scenarios_eachRuleTicksItsOwnCheck() {
        var low = plain(); low.startPct = 18
        var rain = plain(); rain.wet = "rain"
        var gps = plain(); gps.gapGpsS = 25
        var heavy = plain(); heavy.loadKg = 15
        var heavy2 = plain(); heavy2.loadLevel = "heavy"
        var fresh = plain(); fresh.firstOnItsRoute = true
        XCTAssertEqual(ids([low]), ["p6lb"])
        XCTAssertEqual(ids([rain]), ["p6rain"])
        XCTAssertEqual(ids([gps]), ["p6gps"])
        XCTAssertEqual(ids([heavy]), ["p6load"])
        XCTAssertEqual(ids([heavy2]), ["p6load"])
        XCTAssertEqual(ids([fresh]), ["p6route"])
        XCTAssertEqual(ids([plain(offset: 840)]), ["p6night"])           // 22:53 local
        var unknownWeather = plain(); unknownWeather.wet = nil
        XCTAssertEqual(ids([unknownWeather]), [])
    }

    func test_scenarios_markBasedRules() {
        let r = plain()
        XCTAssertEqual(ids([r], ScenarioMarks(lowPowerAt: [base + 1_000])), ["p6lpm"])
        XCTAssertEqual(ids([r], ScenarioMarks(lowPowerAt: [base + 9_000_000])), [])
        var left = r; left.endReason = "standstill"
        XCTAssertEqual(ids([left]), ["p6left"])
        var held = r; held.endReason = "held"
        XCTAssertEqual(ids([held]), [])
        XCTAssertEqual(ids([r], ScenarioMarks(chargedAfterRideIds: ["r1"])), ["p6chg"])
        XCTAssertEqual(ids([r], ScenarioMarks(chargedAfterRideIds: ["other"])), [])
    }

    func test_scenarios_pocketRide_needsTrackingAndNoScreenOnMark() {
        let r = plain()
        XCTAssertEqual(ids([r], ScenarioMarks(screenTrackingSince: base - 1_000)), ["p6pocket"])
        XCTAssertEqual(ids([r], ScenarioMarks(screenOnAt: [base + 100_000], screenTrackingSince: base - 1_000)), [])
        XCTAssertEqual(ids([r], ScenarioMarks(screenTrackingSince: nil)), [])                // never tracked: unknown
        XCTAssertEqual(ids([r], ScenarioMarks(screenTrackingSince: base + 5_000_000)), [])    // ride before tracking began
        var short = r; short.totalS = 120
        XCTAssertEqual(ids([short], ScenarioMarks(screenTrackingSince: base - 1_000)), [])
    }

    func test_scenarios_noteHasCountAndDay_noCoordinates() {
        let v = ScenarioRules.evaluate([plain(offset: 840)], marks: ScenarioMarks())
        XCTAssertEqual(v.first?.id, "p6night")
        XCTAssertTrue(v.first?.note.contains("1 ride") == true)
        XCTAssertEqual(ScenarioRules.ids.count, 10)
    }

    // MARK: Live ETA marks

    typealias XY = SyntheticRoutes.XY

    private func geo(_ p: XY) -> GeoPoint {
        let c = SyntheticRoutes.coordinate(p)
        return GeoPoint(lat: c.lat, lon: c.lon)
    }

    func test_driver_recordsTheShownArrivalAt25_50_75Percent() throws {
        let path = Geo.resample(SyntheticRoutes.main.map { geo($0) }, stepM: 10)
        let follower = try XCTUnwrap(RouteFollower(destinationName: "Work", path: path, todayS: 540))
        let total = follower.totalM
        var d = LiveScreenDriver()
        d.follow(follower, utcOffsetMin: 0)
        func feed(_ fraction: Double, at t: Double) {
            let p = geo(SyntheticRoutes.point(on: SyntheticRoutes.main, at: total * fraction))
            _ = d.update(LiveInput(scooterSpeedKmh: 25, scooterBatteryPct: 80, phase: .riding, lat: p.lat, lon: p.lon,
                                   rideElapsedS: t, rideDistanceM: total * fraction), at: 1_000_000 + t)
        }
        feed(0.05, at: 10)
        XCTAssertEqual(d.etaMarks.count, 0)
        feed(0.30, at: 100)
        XCTAssertEqual(d.etaMarks.map(\.percent), [25])
        feed(0.55, at: 200)
        feed(0.80, at: 300)
        XCTAssertEqual(d.etaMarks.map(\.percent), [25, 50, 75])
        XCTAssertGreaterThan(d.etaMarks[0].arrivalS, 1_000_000)
        feed(0.95, at: 400)
        XCTAssertEqual(d.etaMarks.count, 3)           // each mark once
        d.follow(nil)
        XCTAssertTrue(d.etaMarks.isEmpty)
    }
}
