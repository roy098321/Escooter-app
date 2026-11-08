import XCTest
@testable import CorckieCore

/// Batch 3 (103.081126.00). Made-up readings only.
final class Batch103Tests: XCTestCase {

    private func frame(_ t: Double, speed: Double? = 0, pct: Int? = 80, odo: Double? = 100, tempC: Double? = nil,
                       noTemp: Bool = false, current: Double? = 0) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = speed
        f.batteryPct = pct
        f.odometerKm = odo
        f.voltage = 50
        f.temperatureC = tempC
        f.temperatureNoReading = noTemp
        f.currentA = current
        return f
    }

    // MARK: B73 · nothing from an earlier connection is a reading of this one (every metric)

    func testReconnectClearsEveryScooterValue() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, speed: 0, pct: 62, odo: 1_370.4, tempC: 87, current: 0)), at: 1)
        XCTAssertEqual(e.temperatureC, 87)
        e.handle(.disconnected, at: 2)
        e.handle(.connected, at: 50_000)
        XCTAssertNil(e.temperatureC, "temperature")
        XCTAssertNil(e.batteryPct, "battery %")
        XCTAssertNil(e.odometerKm, "odometer")
        XCTAssertNil(e.speedKmh, "speed")
        XCTAssertNil(e.currentA, "current")
        XCTAssertNil(e.powerW, "power")
    }

    func testBootFrameWithoutTemperatureNeverBringsBackTheOldOne() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, tempC: 87)), at: 1)
        // same connection: the scooter says "no reading yet" (0xFFFF) → cleared, not kept
        e.handle(.frame(frame(2, tempC: nil, noTemp: true)), at: 2)
        XCTAssertNil(e.temperatureC)
        // a frame that simply has no packet B value keeps this connection's value
        e.handle(.frame(frame(3, tempC: 60)), at: 3)
        e.handle(.frame(frame(4, tempC: nil, noTemp: false)), at: 4)
        XCTAssertEqual(e.temperatureC, 60)
    }

    func testFrameAssemblerMarksTheNoReadingSentinel() {
        var a = FrameAssembler()
        let b: [UInt8] = [0xFF, 0xFF, 0x96, 0x00, 0, 0, 0, 0, 0, 0, 0]
        let f = a.ingest(b, at: 0)
        XCTAssertEqual(f?.temperatureNoReading, true)
        XCTAssertNil(f?.temperatureC)
        let real: [UInt8] = [0x3C, 0x00, 0x96, 0x00, 0, 0, 0, 0, 0, 0, 0]
        let g = a.ingest(real, at: 1)
        XCTAssertEqual(g?.temperatureNoReading, false)
        XCTAssertEqual(g?.temperatureC, 60)
    }

    func testRideKeepsItsLastBatteryThroughAReconnect() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, speed: 15, pct: 70, current: 5)), at: 1)
        XCTAssertTrue(e.rideActive)
        e.handle(.disconnected, at: 2)
        e.handle(.connected, at: 3)
        e.handle(.frame(frame(4, speed: 15, pct: nil, current: 5)), at: 4)   // settling: no % yet
        XCTAssertNil(e.batteryPct)
        XCTAssertEqual(e.ride?.lastBatteryPct, 70, "the ride's own record stays")
    }

    // MARK: B74 · 25 and 50 m places

    func testSmallPlaceCircles() {
        XCTAssertEqual(Array(PlaceListBuilder.radiusChoices.prefix(2)), [25, 50])
        let p = PlaceInfo(id: "p", point: GeoPoint(lat: 0, lon: 0), radiusM: 25)
        XCTAssertTrue(PlaceMatcher.reaches(p, GeoPoint(lat: 0.00018, lon: 0), tripLengthM: 5_000), "20 m: inside")
        XCTAssertFalse(PlaceMatcher.reaches(p, GeoPoint(lat: 0.00036, lon: 0), tripLengthM: 5_000), "40 m: outside")
        XCTAssertEqual(TripRules.widenRadius(endDistancesM: [30, 45], radiusM: 25, choices: PlaceListBuilder.radiusChoices), 50)
        XCTAssertEqual(TripRules.widenRadius(endDistancesM: [60, 90], radiusM: 50, choices: PlaceListBuilder.radiusChoices), 100)
    }

    // MARK: B75 · fuel price: 3 digits, the point goes in by itself

    func testFuelPriceEntry() {
        XCTAssertEqual(FuelPriceEntry.format("8"), "8")
        XCTAssertEqual(FuelPriceEntry.format("82"), "8.2")
        XCTAssertEqual(FuelPriceEntry.format("827"), "8.27")
        XCTAssertEqual(FuelPriceEntry.format("8270"), "8.27", "a 4th digit is ignored")
        XCTAssertEqual(FuelPriceEntry.format("8.27"), "8.27", "pasted with a point")
        XCTAssertEqual(FuelPriceEntry.format(""), "")
        XCTAssertNil(FuelPriceEntry.value("8.2"), "not all 3 digits yet")
        XCTAssertEqual(FuelPriceEntry.value("8.27") ?? 0, 8.27, accuracy: 1e-9)
        XCTAssertNil(FuelPriceEntry.value("0.00"))
    }

    // MARK: B76 · the ride screen waits for the real ride

    func testWheelingOutKeepsTheRideInTheBackground() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        // scooter on, wheeled out at walking pace with no motor power for 20 s
        for t in stride(from: 1.0, through: 20, by: 0.5) {
            e.handle(.frame(frame(t, speed: 3, current: 0)), at: t)
        }
        XCTAssertTrue(e.rideActive, "recording quietly in the background (B62)")
        XCTAssertFalse(e.liveInput(at: 20).ridingEngaged, "no ride screen yet")
        // rides off: motor power and 12 km/h for a few seconds
        for t in stride(from: 20.5, through: 30, by: 0.5) {
            e.handle(.frame(frame(t, speed: 12, current: 6)), at: t)
        }
        XCTAssertTrue(e.liveInput(at: 30).ridingEngaged, "the real ride started: the screen opens")
    }

    func testStartByHandEngagesAtOnce() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(1, speed: 0)), at: 1)
        e.handle(.startPressed, at: 2)
        XCTAssertTrue(e.liveInput(at: 2).ridingEngaged)
    }

    // MARK: V-U1 · above usual (Level 1) and extreme (Level 2)

    /// Shaped like the owner's 28 rides: median ≈ 2.66 %/km, p90 ≈ +12 %, worst ≈ +16 %
    private let ownerLike: [Double] = [2.35, 2.41, 2.44, 2.48, 2.50, 2.54, 2.55, 2.58, 2.60, 2.61, 2.63, 2.64, 2.65, 2.66,
                                       2.66, 2.68, 2.70, 2.72, 2.74, 2.78, 2.82, 2.87, 2.89, 2.91, 2.95, 2.98, 3.02, 3.09]

    func testLinesFromTheRidersOwnSpread() {
        let l = UsageLines.from(perKm: ownerLike)
        XCTAssertEqual(l.level1Share, 0.12, accuracy: 0.02, "Level 1 ≈ +12 %")
        XCTAssertEqual(l.level2Share, 0.32, accuracy: 0.04, "Level 2 ≈ 2 × the worst (+16 %)")
        let new = UsageLines.from(perKm: [2.6, 2.7, 2.8])
        XCTAssertEqual(new.level1Share, 0.15)
        XCTAssertEqual(new.level2Share, 0.40)
        let tight = UsageLines.from(perKm: Array(repeating: 2.6, count: 12))
        XCTAssertEqual(tight.level1Share, 0.10, "never under +10 %")
        XCTAssertEqual(tight.level2Share, 0.20, accuracy: 1e-9, "at least 10 points above Level 1")
    }

    /// Rides 6 km at a fixed energy use per km (Wh/% = 8), heading changes every km. Returns the causes said and the km.
    private func ride(pctPerKm: Double, usual: Double = 2.66, km: Double = 6, livePctPerKm: Double? = nil,
                      headings: [Double] = [0, 180], lines: UsageLines = .newRider) -> [(UsageWatch.Cause, Double)] {
        var w = UsageWatch()
        var out: [(UsageWatch.Cause, Double)] = []
        let speed = 20.0, wh = 8.0
        let kmPerS = speed / 3600
        let watts = pctPerKm * wh * speed            // %/km × Wh/% × km/h = W
        var t = 0.0, d = 0.0
        while d <= km {
            let course = headings[Int(d) % headings.count]
            let live = 90 - d * (livePctPerKm ?? pctPerKm)
            if let c = w.update(t: t, rideKm: d, livePct: live, powerW: watts, speedKmh: speed, courseDeg: course,
                                whPerPct: wh, usualPctPerKm: usual, lines: lines) { out.append((c, d)) }
            t += 1
            d += kmPerS
        }
        return out
    }

    func testNormalRideIsQuiet() {
        XCTAssertTrue(ride(pctPerKm: 2.8).isEmpty, "+5 %: nothing")
        XCTAssertTrue(ride(pctPerKm: 2.66 * 1.25, headings: [90]).isEmpty, "+25 % one way (wind): below the line, no drag pattern")
    }

    func testDragInBothDirections() {
        let said = ride(pctPerKm: 2.66 * 1.45)
        XCTAssertEqual(said.first?.0, .drag, "high both ways = brakes / tyres")
        XCTAssertEqual(said.count, 1, "once")
    }

    func testFarAboveWithoutAPattern() {
        let said = ride(pctPerKm: 2.66 * 1.5, headings: [90])
        XCTAssertEqual(said.first?.0, .unknown)
        XCTAssertGreaterThanOrEqual(said.first?.1 ?? 0, UsageWatch.windowKm, "held over 2 km first")
    }

    func testBatteryDrainingFasterThanTheEnergyDrawn() {
        let said = ride(pctPerKm: 2.66, livePctPerKm: 2.66 * 2.2, headings: [90])
        XCTAssertEqual(said.first?.0, .battery)
    }

    func testLevelTwoReplacesLevelOne() {
        var d = V09Director()
        var said: [V09Message] = []
        let wh = 8.0, speed = 20.0
        var t = 0.0, km = 0.0
        while km <= 8 {
            var i = V09Input(t: t, pct: 95 - km * 2.66 * 1.6, rideKm: km, speedKmh: speed, courseDeg: km.truncatingRemainder(dividingBy: 2) < 1 ? 0 : 180,
                             usualPctPerKm: 2.66, powerW: 2.66 * 1.6 * wh * speed, currentA: 8, whPerPct: wh)
            i.usageLines = UsageLines.from(perKm: ownerLike)
            said += d.update(i)
            t += 1
            km += speed / 3600
        }
        XCTAssertTrue(said.contains(.unusualDrag), said.map(\.line).joined(separator: " | "))
        XCTAssertFalse(said.contains { if case .usingMore = $0 { return true } else { return false } }, "never both for one problem")
    }

    func testRidePageNote() {
        var n = V09Numbers()
        n.rideKm = 5.6
        let notes = UsageAlarmNote.insights(rideId: "r", routeId: nil, said: [V09SaidLine(.everyTen(pct: 60), numbers: n),
                                                                                V09SaidLine(.unusualDrag, numbers: n)], nowMs: 1)
        XCTAssertEqual(notes.map(\.text), ["Unusual drag from km 6. Check brakes and tyres."])
        XCTAssertEqual(notes.first?.type.insightClass, .safety)
        XCTAssertTrue(V09Message.unusualDrag.urgent)
    }

    // MARK: V-U2 · battery decay report and notices

    private let day: Int64 = 86_400_000

    /// A made-up rider: a 15 km ride every 2 days for `years`; new range 38 km; `wearPerYear` health points lost a year;
    /// winter (10 °C) shortens the range by 15 % for a while and summer is 25 °C.
    private func decayRides(years: Double, wearPerYear: Double) -> [DecayRide] {
        var out: [DecayRide] = []
        var t: Int64 = 0
        while Double(t) < years * 365 * Double(day) {
            let dayOfYear = Double(t / day % 365)
            let temp = 17.5 + 7.5 * cos(dayOfYear / 365 * 2 * .pi)          // 25 °C at day 0, 10 °C half a year later
            let cold = temp < 20 ? 1 - 0.02 * (20 - temp) * 0.75 : 1.0      // down to −15 % at 10 °C
            let health = 1 - wearPerYear / 100 * Double(t) / (365 * Double(day))
            let km = 38 * health * cold
            out.append(DecayRide(startAt: t, distanceM: 15_000, usedPct: 15 / km * 100, airTempC: temp))
            t += 2 * day
        }
        return out
    }

    func testDecayLevelsAndSeverity() {
        XCTAssertNil(BatteryDecay.level(health: 92))
        XCTAssertEqual(BatteryDecay.level(health: 88), 90)
        XCTAssertEqual(BatteryDecay.level(health: 85), 85)
        XCTAssertEqual(BatteryDecay.level(health: 69), 70)
        XCTAssertEqual(BatteryDecay.severity(level: 85), .low)
        XCTAssertEqual(BatteryDecay.severity(level: 75), .medium)
        XCTAssertEqual(BatteryDecay.severity(level: 60), .high)
        XCTAssertEqual(DecaySeverity.high.title, "Battery worn")
    }

    func testStillLearningAtFirst() {
        let r = BatteryDecay.report(rides: decayRides(years: 0.1, wearPerYear: 0), nowMs: Int64(0.1 * 365) * day)
        guard case let .learning(weeks, km) = r.state else { return XCTFail("\(r.state)") }
        XCTAssertGreaterThan(weeks, 0)
        XCTAssertNotNil(km)
        XCTAssertNil(r.level)
    }

    func testWinterIsNotWear() {
        let rides = decayRides(years: 2.5, wearPerYear: 0)
        var levels: [Int] = []
        var at = 120 * day
        while at < Int64(2.5 * 365) * day {
            let r = BatteryDecay.report(rides: rides.filter { $0.startAt <= at }, nowMs: at)
            if let l = r.level { levels.append(l) }
            at += 15 * day
        }
        XCTAssertTrue(levels.isEmpty, "no wear, cold winters: no notice (\(levels))")
    }

    func testEachLevelOnceAsTheBatteryWears() {
        let rides = decayRides(years: 7, wearPerYear: 5)
        var sent: Set<Int> = []
        var said: [Int] = []
        var at = 120 * day
        while at < Int64(7 * 365) * day {
            let r = BatteryDecay.report(rides: rides.filter { $0.startAt <= at }, nowMs: at)
            if let l = BatteryDecay.noticeLevel(report: r, sent: sent) {
                said.append(l)
                sent.formUnion(stride(from: 90, through: l, by: -5))
            }
            at += 15 * day
        }
        XCTAssertEqual(said, [90, 85, 80, 75, 70], "every 5 % from 90, once each")
    }

    func testReportLeadsWithKilometres() throws {
        let rides = decayRides(years: 5, wearPerYear: 5)
        let now = Int64(5 * 365) * day
        let r = BatteryDecay.report(rides: rides, nowMs: now)
        XCTAssertEqual(r.state, .ready)
        let health = try XCTUnwrap(r.healthPct)
        XCTAssertEqual(health, 79, accuracy: 4, "about 5 points a year after the first year")
        XCTAssertEqual(r.nowKm ?? 0, (r.newKm ?? 0) * health / 100, accuracy: 0.01)
        XCTAssertGreaterThan(r.losingKmPerYear ?? 0, 1)
        XCTAssertNotNil(r.nextLevelKm)
        XCTAssertGreaterThan(r.points.count, 10)
        let words = BatteryDecay.notice(level: 80, report: r)
        XCTAssertEqual(words.title, "Battery wearing")
        XCTAssertTrue(words.body.hasPrefix("A full battery now takes you about"), words.body)
    }

    func testReplacedBatteryStartsOver() {
        let rides = decayRides(years: 5, wearPerYear: 5)
        let now = Int64(5 * 365) * day
        let r = BatteryDecay.report(rides: rides, nowMs: now, resetAtMs: now - 10 * day)
        guard case .learning = r.state else { return XCTFail("a new battery learns again") }
        XCTAssertNil(r.level)
    }

    /// The owner's 3 Nov case: 87 °C from yesterday, scooter on, waiting > 20 s before setting off → no engine line.
    func testNoEngineLineBeforeTheMotorRan() {
        var d = V09Director()
        var said: [V09Message] = []
        for t in stride(from: 0.0, through: 60, by: 1) {
            said += d.update(V09Input(t: t, pct: 98, tempC: 87, rideKm: 0, speedKmh: 0, currentA: 0))
        }
        XCTAssertFalse(said.contains { $0.kind == "hot" || $0.kind == "overheat" || $0.line.hasPrefix("Engine") }, said.map(\.line).joined())
        // the motor pushes, the reading stays hot for 20 s → said once
        for t in stride(from: 61.0, through: 90, by: 1) {
            said += d.update(V09Input(t: t, pct: 97, tempC: 87, rideKm: 0.2, speedKmh: 20, currentA: 6))
        }
        XCTAssertEqual(said.filter { $0 == .engineHot(c: 87) }.count, 1)
    }
}
