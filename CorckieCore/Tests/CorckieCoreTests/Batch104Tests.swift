import XCTest
@testable import CorckieCore

/// Batch 4 (104.151126.00): guard tests N4-3 … N4-16. Made-up rides and readings only (no real places, no real rides).
final class Batch104Tests: XCTestCase {

    // MARK: Made-up ride: 20 km/h, 1 reading a second, energy 2.5 %/km on 8 Wh per 1 %; the scooter's own % sags under load

    private struct Tick { var t: Double; var km: Double; var raw: Double; var powerW: Double; var currentA: Double; var speed: Double }

    /// `sagAt`: raw reading minus this (load sag) at a km; `realPerKm`: how fast the battery REALLY falls (raw), energy stays 2.5
    private func madeUpRide(km total: Double = 24, start: Double = 99, sag: (Double) -> Double = { _ in 0 },
                            realPerKm: Double = 2.5, stopEveryKm: Double? = nil, stopS: Double = 90) -> [Tick] {
        let wh = 8.0, speed = 20.0
        var out: [Tick] = []
        var t = 0.0, km = 0.0, nextStop = stopEveryKm ?? .infinity
        while km <= total {
            let raw = max(0, start - km * realPerKm - sag(km))
            out.append(Tick(t: t, km: km, raw: raw, powerW: 2.5 * wh * speed, currentA: 8, speed: speed))
            if km >= nextStop {
                for s in 1...Int(stopS) {
                    out.append(Tick(t: t + Double(s), km: km, raw: max(0, start - km * realPerKm), powerW: 0, currentA: 0, speed: 0))
                }
                t += stopS
                nextStop += stopEveryKm ?? .infinity
            }
            t += 1
            km += speed / 3600
        }
        return out
    }

    private let wh = 8.0

    private func input(_ k: Tick, usual: Double? = 2.5) -> V09Input {
        V09Input(t: k.t, pct: k.raw, rideKm: k.km, speedKmh: k.speed, usualPctPerKm: usual, powerW: k.powerW, currentA: k.currentA,
                 whPerPct: wh)
    }

    // MARK: N4-6 = B86 · Start on a quietly recording ride opens the dashboard at once

    private func frame(_ t: Double, speed: Double, current: Double) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = speed
        f.batteryPct = 80
        f.odometerKm = 100
        f.voltage = 50
        f.currentA = current
        return f
    }

    func test_N4_6_startOnAQuietRideEngagesOnTheSameTick() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        for t in stride(from: 1.0, through: 20, by: 0.5) { e.handle(.frame(frame(t, speed: 3, current: 0)), at: t) }
        XCTAssertTrue(e.rideActive, "a quiet ride is open")
        XCTAssertFalse(e.liveInput(at: 20).ridingEngaged)
        e.handle(.startPressed, at: 20.2)
        XCTAssertTrue(e.liveInput(at: 20.2).ridingEngaged, "Start = the ride screen opens at once (B86)")
    }

    // MARK: N4-7 = B87 · no repeated "Riding to …" after a relaunch

    func test_N4_7_resumedRideDoesNotRepeatTheDestination() {
        var a = DestinationAnnouncer()
        a.resume(saidKey: "place:p1")
        XCTAssertFalse(a.update(riding: true, key: "place:p1", at: 0))
        XCTAssertFalse(a.update(riding: true, key: "place:p1", at: 30), "already said before the relaunch")
        XCTAssertTrue(a.update(riding: true, key: "place:p2", at: 40), "a change is still said")
        var b = DestinationAnnouncer()
        b.resume(saidKey: nil)
        XCTAssertFalse(b.update(riding: true, key: "place:p1", at: 0), "not known: taken over silently")
        XCTAssertTrue(b.update(riding: true, key: "place:p2", at: 10))
        var fresh = DestinationAnnouncer()
        XCTAssertFalse(fresh.update(riding: true, key: "place:p1", at: 0))
        XCTAssertTrue(fresh.update(riding: true, key: "place:p1", at: 10), "a new ride still says it once")
    }

    func test_N4_7_rememberedAcrossAJSONRoundTrip() throws {
        var s = RideBatteryLevel(rideKey: 1234)
        s.announcedKey = "place:p1"
        s.arrivedSaid = true
        let back = try JSONDecoder().decode(RideBatteryLevel.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.announcedKey, "place:p1")
        XCTAssertTrue(back.arrivedSaid)
        XCTAssertEqual(back.rideKey, 1234)
    }

    // MARK: N4-9 = B88 · voice and map agree on every 10 %

    func test_N4_9_voiceAndMapMarkSameKm() {
        let ride = madeUpRide(sag: { km in km >= 2.8 && km < 3.0 ? 7 : 0 })
        var d = V09Director()
        var voiceKm: [Int: Double] = [:]
        for k in ride {
            for m in d.update(input(k, usual: nil)) { if case let .everyTen(p, _) = m { voiceKm[p] = k.km } }
        }
        let points = ride.map { SeriesPoint(t: $0.t, lat: 10 + $0.km / 111.195, lon: 20, hAccM: 5, speedKmh: $0.speed,
                                            batteryPct: Int($0.raw.rounded()), powerW: $0.powerW) }
        let marks = BatteryMarks.marks(points, whPerPct: wh)
        XCTAssertFalse(voiceKm.isEmpty)
        for (level, km) in voiceKm {
            guard let mark = marks.first(where: { $0.level == level }) else { return XCTFail("no map mark for \(level)") }
            XCTAssertEqual((mark.point.lat - 10) * 111.195, km, accuracy: 0.02, "\(level)%: the pill sits where the voice spoke")
        }
    }

    func test_N4_9_sharedLevelGivesTheSameLinesAsTheVoicesOwn() {
        let ride = madeUpRide(sag: { km in km >= 2.8 && km < 3.0 ? 7 : 0 })
        var own = V09Director(), shared = V09Director()
        var level = RideBatteryLevel(rideKey: 1)
        var a: [Int] = [], b: [Int] = []
        for k in ride {
            for m in own.update(input(k, usual: nil)) { if case let .everyTen(p, _) = m { a.append(p) } }
            let reached = level.update(t: k.t, livePct: k.raw, powerW: k.powerW, currentA: k.currentA, speedKmh: k.speed, whPerPct: wh)
            var i = input(k, usual: nil)
            i.levelPct = level.level
            i.levelStartPct = level.startPct
            i.tensReached = reached
            for m in shared.update(i) { if case let .everyTen(p, _) = m { b.append(p) } }
        }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.first, 90)
    }

    // MARK: N4-10 = B89 · no battery lines after "Arrived"

    func test_N4_10_noTenPercentLineAfterArrived() {
        var d = V09Director()
        var said: [V09Message] = []
        var arrived = false
        for k in madeUpRide(km: 14) {
            if !arrived, k.km >= 11.6 { d.muteAfterArrival(); arrived = true }   // "Arrived at Uni, battery at sixty eight percent."
            let out = d.update(input(k, usual: nil))
            if arrived { said += out }
        }
        XCTAssertFalse(said.contains { $0.kind == "ten" }, said.map(\.line).joined(separator: " | "))
    }

    func test_N4_10_arrivalLineSaysTheSmoothedLevel() {
        var a = ArrivalLineTracker()
        XCTAssertEqual(a.arrived(place: "Uni", pct: 68.4, rideKm: 13.8)?.line, "Arrived at Uni, battery at sixty eight percent.")
        XCTAssertNil(a.rideEnded(pct: 67, rideKm: 13.9), "once")
    }

    // MARK: N4-11 = B90 · drain warning: fewer false alarms

    private func warnings(_ ride: [Tick]) -> [V09Message] {
        var d = V09Director()
        var out: [V09Message] = []
        for k in ride { out += d.update(input(k)).filter { ["drain", "far", "drag"].contains($0.kind) } }
        return out
    }

    func test_N4_11_sagAndFastFallOffAFullChargeDoNotWarn() {
        // like the 9 / 10 / 11 Nov rides: off a full charge the reading falls fast, and sags 7 points for 40 s at km 2.8
        let ride = madeUpRide(start: 100, sag: { km in (km < 4 ? km * 1.5 : 6) + (km >= 2.8 && km < 3.0 ? 7 : 0) })
        XCTAssertEqual(warnings(ride), [])
    }

    func test_N4_11_aRealDoubleDrainStillWarns() {
        let ride = madeUpRide(km: 14, realPerKm: 5.0, stopEveryKm: 1, stopS: 90)
        let w = warnings(ride)
        XCTAssertEqual(w.first?.kind, "drain", w.map(\.line).joined(separator: " | "))
    }

    func test_N4_11_thresholds() {
        XCTAssertEqual(UsageWatch.drainRatio, 1.8)
        XCTAssertEqual(UsageWatch.drainMinPts, 8)
    }

    // MARK: N4-5 · the calmer lines with the rate

    func test_N4_5_calmerLinesCarryTheRate() {
        XCTAssertEqual(V09Message.everyTen(pct: 90, pctPerKm: 2.5).line, "Battery at ninety percent, using two point five percent per kilometre.")
        XCTAssertEqual(V09Message.everyTen(pct: 90).line, "Battery at ninety percent.")
        XCTAssertEqual(V09Message.drainingFast(pctPerKm: 2.5).line, "Energy use higher than normal, using two point five percent per kilometre.")
        XCTAssertEqual(V09Message.farAboveUsual(pctPerKm: 3.04).line, "Energy use higher than normal, using three point zero percent per kilometre.")
        XCTAssertEqual(V09Message.unusualDrag.line, "Unusual drag, check brakes and tyres.", "names an action: unchanged")
        XCTAssertNil(V09Message.rideRate(startPct: 99, levelPct: 97, rideKm: 0.8), "only after 1 km")
        XCTAssertEqual(V09Message.rideRate(startPct: 99, levelPct: 94, rideKm: 2) ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(UsageAlarmNote.text(kind: "drain", km: 5.6, pctPerKm: 2.5), "Energy use higher than normal from km 6, 2.5 % per km.")
        XCTAssertEqual(UsageAlarmNote.text(kind: "far", km: 5.6, pctPerKm: nil), "Energy use higher than normal from km 6.")
        XCTAssertFalse(V09Message.samples.contains { $0.line.contains("abnormally") || $0.line.contains("check the scooter") })
    }

    func test_N4_5_tenPercentLineHasTheRideRateAfterOneKm() {
        var d = V09Director()
        var tens: [V09Message] = []
        for k in madeUpRide(km: 6) { tens += d.update(input(k, usual: nil)).filter { $0.kind == "ten" } }
        guard case let .everyTen(p, rate)? = tens.first else { return XCTFail("no 10 % line") }
        XCTAssertEqual(p, 90)
        XCTAssertEqual(rate ?? 0, 2.5, accuracy: 0.15)
    }

    // MARK: N4-12 = B91 · one end-of-ride number

    func test_N4_12_oneEndLevel() {
        let e = RideBatteryEnds.make(shownUsed: 32.5, usedPct: 31, startRestPct: 99, endRestPct: 67)
        XCTAssertEqual(e.startPct, 99)
        XCTAssertEqual(e.endPct ?? 0, 66.5, accuracy: 1e-9)
        XCTAssertEqual((e.startPct ?? 0) - (e.endPct ?? 0), e.usedPct ?? -1, accuracy: 1e-9, "used = start − end")
        XCTAssertEqual(BatteryLegend.text(e)?.low, "67%")
        XCTAssertEqual(BatteryLegend.text(e)?.high, "99%")
        let m = RideSummaryBuilder.build(RideDetailInput(startAt: 0, distanceM: 13_800, usedPct: 32.5, startRestPct: 99, endRestPct: 67),
                                         gaps: [], points: [])
        XCTAssertEqual(m.mainStats.first { $0.label == "Battery" }?.value, "99% \u{2192} 67%")
        XCTAssertEqual(m.batteryEnds, e)
    }

    // MARK: N4-13 = B92 · the list shows what the ride page shows

    func test_N4_13_listUsesTheShownFigure() {
        XCTAssertEqual(RideBatteryEnds.make(shownUsed: 9, usedPct: nil, startRestPct: nil, endRestPct: nil).usedPct, 9, "B92: was blank")
        XCTAssertEqual(RideBatteryEnds.make(shownUsed: 42, usedPct: 40, startRestPct: 90, endRestPct: 50).usedPct, 42, "the page's figure wins")
        XCTAssertEqual(RideBatteryEnds.make(shownUsed: nil, usedPct: nil, startRestPct: 90, endRestPct: 80).usedPct, 10)
    }

    // MARK: N4-14 = B93 · no "Arrived" for discarded rides and short hops; the destination named

    func test_N4_14_noArrivalForShortRides() {
        var a = ArrivalLineTracker()
        XCTAssertNil(a.rideEnded(pct: 80, rideKm: 0.2), "discarded")
        XCTAssertNil(a.rideEnded(pct: 80, rideKm: 1.5), "short hop")
        XCTAssertNil(a.arrived(place: "Gym", pct: 80, rideKm: 1.2), "short hop into a place")
        XCTAssertEqual(a.rideEnded(pct: 69, rideKm: 13.9, announced: "Uni")?.line, "Arrived at Uni, battery at sixty nine percent.")
        var b = ArrivalLineTracker()
        XCTAssertEqual(b.rideEnded(pct: 69, rideKm: 13.9)?.line, "Arrived, battery at sixty nine percent.", "nothing announced")
    }

    // MARK: N4-15 = B94 · after a relaunch the level is re-seeded from the live reading

    func test_N4_15_reseedAfterARelaunch() throws {
        var s = RideBatteryLevel(rideKey: 7)
        // before the relaunch: the energy says 90 while the scooter still reads 99 (no rest to nudge it)
        var t = 0.0, km = 0.0
        while km < 3.6 {
            s.update(t: t, livePct: 99, powerW: 4 * wh * 20, currentA: 8, speedKmh: 20, whPerPct: wh)
            t += 1
            km += 20.0 / 3600
        }
        XCTAssertLessThan(s.level ?? 100, 91)
        var back = try JSONDecoder().decode(RideBatteryLevel.self, from: JSONEncoder().encode(s))
        back.resumed(at: t)
        var reached: [Int] = []
        reached += back.update(t: t, livePct: 99, powerW: 400, currentA: 8, speedKmh: 20, whPerPct: wh)
        XCTAssertEqual(back.level ?? 0, 99, accuracy: 0.01, "the live reading again")
        for s2 in 1...60 { reached += back.update(t: t + Double(s2), livePct: 99, powerW: 400, currentA: 8, speedKmh: 20, whPerPct: wh) }
        XCTAssertFalse(reached.contains(90), "no \"ninety\" while the scooter reads 99")
    }

    func test_N4_15_resumeWithNoSavedStateStartsFromTheReading() {
        var s = RideBatteryLevel(rideKey: 8)
        s.resumed(at: 0)
        // the first reading after the relaunch is under load (sagged); the higher one a few seconds later wins
        var reached = s.update(t: 0, livePct: 93, powerW: 400, currentA: 8, speedKmh: 20, whPerPct: wh)
        reached += s.update(t: 1, livePct: 96, powerW: 400, currentA: 8, speedKmh: 20, whPerPct: wh)
        XCTAssertEqual(s.level ?? 0, 96, accuracy: 0.01)
        XCTAssertEqual(reached, [])
        XCTAssertEqual(s.startPct ?? 0, 96, accuracy: 0.01)
    }

    // MARK: N4-16 · the dashboard shows the one smoothed level (D-PR-09)

    func test_N4_16_dashboardShowsTheSmoothedLevel() {
        var level = RideBatteryLevel(rideKey: 9)
        var builder = LiveStateBuilder()
        var d = V09Director()
        var shown: [Int] = []
        // raw 99 → 92 → 95 under load at about km 2.8 (40 s), as on 11 Nov; energy is normal
        for k in madeUpRide(km: 3.4, sag: { km in km >= 2.8 && km < 3.0 ? 7 : (km >= 3.0 && km < 3.2 ? 4 : 0) }) {
            level.update(t: k.t, livePct: k.raw, powerW: k.powerW, currentA: k.currentA, speedKmh: k.speed, whPerPct: wh)
            var i = LiveInput(scooterSpeedKmh: k.speed, scooterBatteryPct: k.raw)
            i.smoothedBatteryPct = level.level
            let tile = builder.update(i)
            shown.append(tile.batteryPct ?? -1)
            var v = input(k, usual: nil)
            v.levelPct = level.level
            v.levelStartPct = level.startPct
            _ = d.update(v)
            XCTAssertEqual(d.numbers.levelPct, level.level, "the voice's number is the dashboard's number")
            XCTAssertEqual(tile.batteryPct, level.level.map { Int($0.rounded()) })
        }
        // no 7-point jump: the shown number only steps down, a point at a time
        for (a, b) in zip(shown, shown.dropFirst()) { XCTAssertTrue(b <= a && a - b <= 1, "\(a) → \(b)") }
        // phone-only rides keep "~ est."
        var phone = LiveInput(scooterLinked: false, estimatedBatteryPct: 55)
        phone.smoothedBatteryPct = nil
        XCTAssertEqual(builder.update(phone).batteryText, "~55% est.")
    }

    // MARK: N4-3 = B84 · "No rise in battery use"

    func test_N4_3_passedTheMarkWithoutARiseSaysSo() {
        let made = InsightProgressBuilder.make([.learning(.creep, "16 of 8 rides")])
        guard let p = made.progress.first else { return XCTFail("no card") }
        XCTAssertEqual(p.headline, "No rise in battery use")
        XCTAssertEqual(p.countLine, "Based on 16 rides")
        XCTAssertLessThan(p.fraction, 1, "the bar stops before the confident mark")
        let before = InsightProgressBuilder.make([.learning(.creep, "5 of 8 rides")]).progress[0]
        XCTAssertEqual(before.headline, "No answer yet")
        XCTAssertEqual(before.countLine, "5 of 8 rides to a first read")
        for n in 0...40 {
            let line = InsightProgressBuilder.make([.learning(.sweetSpot, "\(n) of 12 steady stretches")]).progress[0].countLine
            if let have = InsightProgressBuilder.count(line), let of = line.split(separator: " ").dropFirst(2).first.flatMap({ Int($0) }) {
                XCTAssertLessThanOrEqual(have, of, "never shows have > target: " + line)
            }
        }
    }

    // MARK: N4-4 = B85 · "No clear cost yet", never −0.00

    func test_N4_4_intervalTouchingZeroSaysNoClearCost() {
        XCTAssertNil(RideLevelInsights.clearRange(-0.02, -0.004), "−0.02 to −0.00 touches 0")
        XCTAssertNil(RideLevelInsights.clearRange(-0.02, 0.03))
        XCTAssertEqual(RideLevelInsights.clearRange(0.02, 0.08), "+0.02 to +0.08 % per km")
        XCTAssertEqual(RideLevelInsights.signed(-0.004), "0")
        XCTAssertEqual(RideLevelInsights.signed(0.004), "0")
        XCTAssertEqual(RideLevelInsights.bound(0.016), "0.02")
        XCTAssertFalse(RideLevelInsights.signed(-0.001).contains("\u{2212}0.00"))
    }

    // MARK: N4-8 · Home "Offline" when paired and off

    func test_N4_8_offlineWhenPairedAndOff() {
        let now = 1_790_000_000.0
        let off = HomeLogic.model(HomeInput(paired: true, connected: false, nowS: now))
        XCTAssertEqual(off.primary, .offline)
        XCTAssertEqual(off.primaryTitle, "Offline")
        XCTAssertFalse(off.primaryEnabled, "no action on tap")
        let lost = HomeLogic.model(HomeInput(paired: true, connected: false, connectingSinceS: now - 60, nowS: now))
        XCTAssertEqual(lost.primary, .offline, "no Try again from Home")
        let first = HomeLogic.model(HomeInput(paired: false, connected: false, nowS: now))
        XCTAssertEqual(first.primary, .connect, "first use keeps Connect")
        XCTAssertTrue(first.primaryEnabled)
        XCTAssertEqual(HomeLogic.model(HomeInput(paired: true, connected: true, nowS: now, batteryPct: 80)).primary, .startRide,
                       "turns into Start by itself")
    }

    // MARK: N4-2 · a riding-ask place you can find (made-up streets and points)

    func test_N4_2_theStretchIsNamedByItsStreet() {
        let s = AskStretch(key: "r|a|b", routeName: "Uni", fromKm: 3.5, path: [GeoPoint(lat: 10, lon: 20), GeoPoint(lat: 10.004, lon: 20)])
        XCTAssertEqual(s.line(street: "Main St", fromStreet: "First Ave", toStreet: "Second Ave"),
                       "Try it on Main St, between First Ave and Second Ave (your Uni route, about 3.5 km in).")
        XCTAssertEqual(s.line(street: "Main St", fromStreet: "Main St", toStreet: "Main St"),
                       "Try it on Main St (your Uni route, about 3.5 km in).", "the same street at the ends adds nothing")
        XCTAssertEqual(s.line(street: nil, fromStreet: nil, toStreet: nil), s.line, "offline: the old line, the map still shows where")
        XCTAssertEqual(RidingAsk(speedKmh: 20, metres: 500, stretch: s).anyLine, "Any 500 m steady at 20 km/h counts.")
    }

    func test_N4_2_foundStretchesCarryTheirPath() {
        var pts: [(point: GeoPoint, altM: Double?)] = []
        for i in 0...40 { pts.append((GeoPoint(lat: 10 + Double(i) * 0.000_2, lon: 20), 30)) }   // a straight, level 900 m
        let found = RidingAsks.stretches([AskRoutePath(routeId: "r", name: "Uni", points: pts)], metres: 500, notHere: [])
        XCTAssertFalse(found.isEmpty)
        XCTAssertGreaterThan(found[0].path.count, 2)
        XCTAssertEqual(found[0].start, pts[0].point)
    }

    func test_N4_2_voiceCueOnceOnReachingTheStretch() {
        let a = GeoPoint(lat: 10, lon: 20), b = GeoPoint(lat: 10.0045, lon: 20)
        var cue = AskCue(speedKmh: 20, metres: 500, start: a, end: b)
        XCTAssertEqual(cue.line, "Straight ahead: hold twenty for five hundred metres.")
        XCTAssertFalse(cue.update(position: GeoPoint(lat: 9.998, lon: 20), speedKmh: 20), "still 220 m away")
        XCTAssertFalse(cue.update(position: GeoPoint(lat: 9.9997, lon: 20), speedKmh: 0), "standing")
        XCTAssertTrue(cue.update(position: GeoPoint(lat: 9.9997, lon: 20), speedKmh: 20), "33 m before the start")
        XCTAssertFalse(cue.update(position: GeoPoint(lat: 10.0001, lon: 20), speedKmh: 20), "once")
        var back = AskCue(speedKmh: 20, metres: 500, start: a, end: b)
        XCTAssertFalse(back.update(position: GeoPoint(lat: 10.0046, lon: 20), speedKmh: 20), "near the end: the other way")
        XCTAssertNil(AskCue(RidingAsk(speedKmh: 20, metres: 500, stretch: nil)), "no stretch, no cue")
    }

    // MARK: N4-1 · move a place's circle centre (made-up coordinates)

    func test_N4_1_moveUndoAndTheCircleFollows() {
        let a = GeoPoint(lat: 10, lon: 20), b = GeoPoint(lat: 10.0003, lon: 20)
        var e = CentreEditor(centre: a)
        XCTAssertFalse(e.changed)
        XCTAssertFalse(e.canUndo)
        e.move(to: b)
        XCTAssertTrue(e.changed)
        XCTAssertEqual(e.movedM, 33, accuracy: 1.5)
        // the circle is drawn around the new centre: a point near b is inside a 25 m circle, a is not
        let shape = PlaceShape(center: e.centre, radiusM: 25)
        XCTAssertTrue(shape.contains(GeoPoint(lat: 10.00031, lon: 20)))
        XCTAssertFalse(shape.contains(a))
        e.move(to: b)
        XCTAssertTrue(e.canUndo)
        e.undo()
        XCTAssertEqual(e.centre, a, "one undo step per move")
        XCTAssertFalse(e.changed)
    }
}
