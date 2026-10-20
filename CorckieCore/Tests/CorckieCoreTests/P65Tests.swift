import XCTest
@testable import CorckieCore

/// P6-5 (owner feedback on build 251): B44 / B45 / B46 place estimates, the quick-dial pins, the Past weeks metric, the photo frame, the
/// boot-time battery settle (B50) and the no-racing guard (B47, policy P-3). All on made-up numbers.
final class P65Tests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000

    private func ride(_ id: String, minutes: Double, used: Double? = nil, daysAgo: Double = 1) -> RouteRideStats {
        RouteRideStats(rideId: id, startAt: now - Int64(daysAgo * 86_400_000), totalS: minutes * 60, distanceM: 3000, usedPct: used)
    }

    // MARK: B44 / B45

    func test_B44_noRidesThere_saysSoAndGivesNoTime() {
        let v = PlaceRides.verdict(rides: [], nowMs: now, utcOffsetMin: 180)
        XCTAssertEqual(v, .none)
        XCTAssertEqual(PlaceRides.note(v), "no rides there yet")
        XCTAssertEqual(QuickDial.summary(name: "Grandma", minutes: nil, needPct: nil, note: PlaceRides.note(v)), "Grandma \u{00B7} no rides there yet")
    }

    func test_B45_twoRidesGiveARoughEstimate_oneRideSaysEstimateAfter2() {
        let one = PlaceRides.verdict(rides: [ride("a", minutes: 12)], nowMs: now, utcOffsetMin: 180)
        XCTAssertEqual(one, .tooFew(have: 1))
        XCTAssertEqual(PlaceRides.note(one), "1 ride there \u{00B7} estimate after 2")
        let two = PlaceRides.verdict(rides: [ride("a", minutes: 12, used: 6), ride("b", minutes: 14, used: 8)], nowMs: now, utcOffsetMin: 180)
        guard case .estimate(let timeS, let used, let n) = two else { return XCTFail("two rides should estimate") }
        XCTAssertEqual(timeS, 13 * 60, accuracy: 1)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(used ?? 0, 7, accuracy: 0.01)
        XCTAssertNil(PlaceRides.note(two))
    }

    func test_B45_threeRidesUseTheUsualTodayEstimate() {
        let rides = (0..<4).map { ride("r\($0)", minutes: 10 + Double($0), used: 5, daysAgo: Double($0) + 1) }
        guard case .estimate(_, _, let n) = PlaceRides.verdict(rides: rides, nowMs: now, utcOffsetMin: 180) else { return XCTFail("estimate expected") }
        XCTAssertEqual(n, 4)
    }

    func test_B45_excludedRidesDoNotCount() {
        var odd = ride("x", minutes: 40)
        odd.excluded = true
        XCTAssertEqual(PlaceRides.verdict(rides: [odd, ride("a", minutes: 12)], nowMs: now, utcOffsetMin: 180), .tooFew(have: 1))
    }

    // MARK: B46

    func test_B46_hereWhenInsideTheCircle() {
        let place = GeoPoint(lat: 32.0, lon: 34.8)
        XCTAssertTrue(PlaceHere.isHere(phone: GeoPoint(lat: 32.0005, lon: 34.8), place: place, radiusM: nil))        // ~55 m
        XCTAssertFalse(PlaceHere.isHere(phone: GeoPoint(lat: 32.01, lon: 34.8), place: place, radiusM: nil))          // ~1.1 km
        XCTAssertFalse(PlaceHere.isHere(phone: GeoPoint(lat: 32.0005, lon: 34.8), place: place, radiusM: 30))
        XCTAssertFalse(PlaceHere.isHere(phone: nil, place: place, radiusM: nil))
        XCTAssertEqual(PlaceHere.tapLine(name: "Home"), "You're at Home")
    }

    // MARK: pins

    func test_pins_maxThree_fourthAsksWhichToReplace() {
        var pins: [String: Int] = [:]
        for id in ["a", "b", "c"] {
            guard case .pinned(let next) = QuickDialSlot.pin(id, in: pins) else { return XCTFail() }
            pins = next
        }
        XCTAssertEqual(pins, ["a": 1, "b": 2, "c": 3])
        XCTAssertEqual(QuickDialSlot.pin("d", in: pins), .needsReplace(candidates: ["a", "b", "c"]))
        XCTAssertEqual(QuickDialSlot.replace("b", with: "d", in: pins), ["a": 1, "d": 2, "c": 3])
        XCTAssertEqual(QuickDialSlot.unpin("a", in: pins), ["b": 1, "c": 2])
        XCTAssertEqual(QuickDialSlot.reordered(["c", "a", "b"]), ["c": 1, "a": 2, "b": 3])
    }

    // MARK: colours

    func test_F29b_glyphIsDarkOnLightColoursAndWhiteOnBlue() {
        XCTAssertTrue(PlaceColours.glyphIsDark(hex: PlaceColours.hex("yellow")))
        XCTAssertTrue(PlaceColours.glyphIsDark(hex: PlaceColours.hex("orange")))
        XCTAssertFalse(PlaceColours.glyphIsDark(hex: PlaceColours.hex("blue")))
    }

    // MARK: Past weeks

    func test_pastWeeks_metricValuesAndTexts() {
        let bar = WeekBar(start: now, km: 61.4, rides: 8, seconds: 4800, savedIls: 34.4)
        XCTAssertEqual(PastWeeksMetric.km.value(bar), 61.4, accuracy: 0.001)
        XCTAssertEqual(PastWeeksMetric.rides.value(bar), 8)
        XCTAssertEqual(PastWeeksMetric.time.value(bar), 80, accuracy: 0.001)
        XCTAssertEqual(PastWeeksMetric.saved.value(bar), 34.4, accuracy: 0.001)
        XCTAssertEqual(PastWeeksMetric.km.valueText(bar), "61 km")
        XCTAssertEqual(PastWeeksMetric.rides.valueText(bar), "8 rides")
        XCTAssertEqual(PastWeeksMetric.time.valueText(bar), "1 h 20")
        XCTAssertEqual(PastWeeksMetric.saved.valueText(bar), "\u{20AA}34")
        XCTAssertEqual(PastWeeksMetric.km.cardTitle, "Past weeks \u{00B7} km")
        XCTAssertEqual(PastWeeksMetric.from(stored: "nonsense"), .km)
        XCTAssertEqual(PastWeeksMetric.from(stored: "time"), .time)
        XCTAssertEqual(PastWeeksMetric.saved.value(WeekBar(start: 0, km: 0, rides: 0)), 0, "no fuel price = 0, never a negative")
    }

    func test_pastWeeks_weekLabel_isTheFirstDay() {
        // 2026-09-06 00:00 UTC
        XCTAssertEqual(PastWeeksMetric.weekLabel(start: 1_788_652_800_000, utcOffsetMin: 0), "6 Sep")
    }

    func test_pastWeeks_barsCarryTimeAndSavings() {
        let week = 7 * OutsideTime.dayMs
        let current = InsightWeek.start(ms: now, utcOffsetMin: 0)
        let startAt = current - 2 * week + OutsideTime.dayMs
        let rides = [StatsRide(startAt: startAt, utcOffsetMin: 0, kind: "ride", distanceM: 10_000, totalS: 1800, usedPct: 10),
                     StatsRide(startAt: startAt + 3_600_000, utcOffsetMin: 0, kind: "ride", distanceM: 5_000, totalS: 900, usedPct: 5)]
        let prices = StatsPrices(packWh: 800, fuelFallbackIls: 8.0)
        let bars = WeekBars.make(statsRides: rides, prices: prices, nowMs: now, utcOffsetMin: 0)
        guard let bar = bars.first(where: { $0.rides == 2 }) else { return XCTFail("the week with rides") }
        XCTAssertEqual(bar.km, 15, accuracy: 0.001)
        XCTAssertEqual(bar.seconds, 2700, accuracy: 0.001)
        XCTAssertNotNil(bar.savedIls)
        XCTAssertGreaterThan(bar.savedIls ?? 0, 0)
    }

    // MARK: Photo frame

    func test_photoFrame_alwaysCoversTheCard() {
        // a wide photo (3:2) on a 1.16 card: at scale 1 it can only move sideways
        let f = PhotoFrame(scale: 1, dx: 5, dy: 5).clamped(imageAspect: 1.5)
        XCTAssertEqual(f.dy, 0, accuracy: 0.0001)
        XCTAssertEqual(f.dx, (1.5 / PhotoFrame.cardAspect - 1) / 2, accuracy: 0.0001)
        // zoomed in it can move both ways, never past the edge
        let z = PhotoFrame(scale: 2, dx: -9, dy: 9).clamped(imageAspect: 1.5)
        XCTAssertGreaterThan(z.dy, 0)
        XCTAssertLessThan(z.dx, 0)
        XCTAssertEqual(PhotoFrame(scale: 99).clamped(imageAspect: 1).scale, PhotoFrame.maxScale)
        XCTAssertEqual(PhotoFrame(scale: 0.2).clamped(imageAspect: 1).scale, 1)
        let back = PhotoFrame.parse(PhotoFrame(scale: 2, dx: 0.1, dy: -0.2).json)
        XCTAssertEqual(back, PhotoFrame(scale: 2, dx: 0.1, dy: -0.2))
        XCTAssertEqual(PhotoFrame.parse(nil), PhotoFrame())
    }

    // MARK: B50

    func test_B50_bootSequenceSettlesOn64() {
        var s = BootSettle()
        var shown: [Int?] = []
        for (i, pct) in [100, 100, 100, 64, 64, 64].enumerated() { shown.append(s.reading(pct: pct, at: Double(i))) }
        XCTAssertEqual(shown.prefix(5).compactMap { $0 }, [], "nothing believed while 100 may be the boot value or the new value is not stable")
        XCTAssertEqual(shown.last ?? nil, 64)
        XCTAssertEqual(s.notifyPct, 64)
    }

    func test_B50_aReallyFullScooterIsBelievedAfter8Seconds() {
        var s = BootSettle()
        for t in 0..<8 { XCTAssertNil(s.reading(pct: 100, at: Double(t))) }
        XCTAssertEqual(s.reading(pct: 100, at: 8), 100)
    }

    func test_B50_aStableLowValueIsBelievedAtOnce_andLaterReadingsPassThrough() {
        var s = BootSettle()
        XCTAssertNil(s.reading(pct: 64, at: 0))
        XCTAssertNil(s.reading(pct: 64, at: 1))
        XCTAssertEqual(s.reading(pct: 64, at: 2), 64)
        XCTAssertEqual(s.reading(pct: 63, at: 600), 63)
    }

    func test_B50_neverSettlingGivesUpAfter15s_withoutAPercentToNotify() {
        var s = BootSettle()
        var t = 0.0
        for pct in [100, 98, 100, 97, 100, 96, 100, 95] { s.reading(pct: pct, at: t); t += 2 }
        s.tick(at: 15)
        XCTAssertTrue(s.gaveUp)
        XCTAssertNil(s.notifyPct, "the notification goes out without a %")
        XCTAssertEqual(s.displayPct, 95, "the screen shows the latest reading instead of nothing forever")
        s.reset()
        XCTAssertNil(s.displayPct)
    }

    // MARK: B47 / P-3: no racing symbols anywhere in the app

    func test_B47_noRacingSymbolsInTheApp() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else { return XCTFail("App not found") }
        let banned = ["flag.checkered", "flag.2.crossed", "trophy", "medal", "stopwatch", "\u{1F3C1}", "\u{1F3C6}", "\u{1F947}", "\u{23F1}"]
        var scanned = 0
        for case let file as URL in walker where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            scanned += 1
            for b in banned {
                XCTAssertFalse(source.contains(b), "\(file.lastPathComponent) contains a racing symbol: \(b) (policy P-3)")
            }
        }
        XCTAssertGreaterThan(scanned, 100)
    }
}
