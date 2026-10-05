import XCTest
@testable import CorckieCore

/// M4-03: every catalogue row's gate (just below / at), the wording of the INSIGHTS.md examples, and the P-3 guard
/// (no reward language in any template).
final class InsightCatalogueTests: XCTestCase {
    private let now = InsightSamples.now
    private let day = FactorSamples.day

    private func v(_ id: String, _ name: String, time: Double, used: Double? = nil, n: Int, gain: Double = 10, dist: Double = 5_000) -> InsightVariant {
        InsightSamples.variant(id, name, timeS: time, usedPct: used, n: n, gainM: gain, distanceM: dist)
    }

    private func texts(_ i: [Insight]) -> [String] { i.map(\.text) }

    // MARK: Wording (INSIGHTS.md examples)

    func test_wording_snapshots() {
        let all = InsightSamples.all()
        func text(_ t: InsightType, ride: String = "r1", progress: Bool = false) -> String? {
            all.first { $0.type == t && $0.rideId == ride && $0.isProgress == progress }?.text
        }
        XCTAssertEqual(text(.q1Live), "Heading to Work? Fastest today: via park shortcut, about 14 min.")
        XCTAssertEqual(text(.q1After), "You took via Ibn Gabirol: 16 min. Via park shortcut is usually 2 min faster but uses 3% more battery "
                       + "(14 min vs 16 min · based on 6 and 8 rides).")
        XCTAssertEqual(text(.q2After, ride: "r2"), "Via Ibn Gabirol uses about 3% less battery than via park shortcut and is usually 2 min slower "
                       + "(based on 8 and 6 rides).")
        XCTAssertEqual(text(.q2Live), "Battery 18%: take via Ibn Gabirol, it uses less.")
        XCTAssertEqual(all.first { $0.type == .q3After && $0.subject == "o1" }?.text,
                       "The park shortcut saved you 1:40 on that stretch (usually saves 1:30–1:45 · based on 3 rides).")
        XCTAssertEqual(all.first { $0.type == .q3Verdict && $0.subject == "o1" }?.text, "Verdict: the park shortcut saves about 1.5 min per ride. Worth it.")
        XCTAssertEqual(all.first { $0.type == .q3Verdict && $0.subject == "o2" }?.text, "Verdict: no real difference with the side street (under 20 s).")
        XCTAssertEqual(text(.q4After), "2 min slower than usual: headwind (~1:10), rush hour (~50 s). 3% more battery than usual: headwind (+2%).")
        XCTAssertEqual(text(.q4After, ride: "r2"), "2.5 min faster than usual (usually 13–15 min · based on 8 rides).")
        XCTAssertEqual(all.first { $0.type == .q4Weekly }?.text,
                       "Biggest factor this week: headwind, which cost you ~3.5 min and ~6% battery in total (based on 3 rides).")
        XCTAssertEqual(text(.q9Live), "Battery 20%: enough for Work, not for the way back.")
        XCTAssertEqual(text(.q13After), "Home to Work: riding flat out saves you ~1.5 min but costs ~3% battery compared to your calmer rides (based on 10 rides).")
        XCTAssertEqual(text(.q13After, progress: true), "Speed cap on Home to Work: 4 of 9 rides")
        XCTAssertEqual(all.first { $0.type == .q13Weekly }?.text,
                       "You rode at the speed cap (25 km/h) 38% of the time this week. That saved ~4 min and cost ~6% battery, about 40 s per 1% of battery.")
        XCTAssertEqual(all.filter { $0.type == .q15Live }.map(\.text), [
            "Headwind today on Home to Work: expect +1:30, +1% battery (based on 6 windy rides).",
            "Tailwind today on Home to Work: expect about 1:20 faster, 1% less battery (based on 6 tailwind rides)."])
        XCTAssertEqual(all.filter { $0.type == .q15After && !$0.isProgress }.map(\.text),
                       ["Tailwind saved you ~1 min and ~2% battery today.", "Headwind cost you ~1 min and ~2% battery today."])
        XCTAssertEqual(text(.q15After, ride: "r2", progress: true), "Headwind on Home to Work: 2 of 3 windy rides")
        XCTAssertEqual(all.first { $0.type == .q15Notify }?.text,
                       "Wind is picking up today: this should cut your range by ~2 km and add ~10 s per km to your ride (Home to Work: +50 s).")
        XCTAssertEqual(text(.q17New), "New climb detected: Bridge ramp (+18 m). We'll track what it costs you.")
        XCTAssertEqual(text(.q18), "Via park shortcut (flatter): +0.8 km, 8 m less climbing → +3% battery, \u{2212}2:00.")
        XCTAssertEqual(text(.q19After), "With a load (Heavy): +2% battery, +30 s compared to usual (based on 4 loaded rides).")
        XCTAssertEqual(text(.q19After, ride: "r2", progress: true), "Load: 2 of 5 loaded rides")
        XCTAssertEqual(all.first { $0.type == .q22Weekly }?.text,
                       "Last week: 20 km · 4 rides · 1 h 0 min · +1 short hop (1.4 km) · Battery used: ~0.4 full charges · ▲ 19% more than the week before")
        XCTAssertEqual(text(.firstRide), "Your first ride is in · Ride the same trip 3 times and you'll see how it compares")
        XCTAssertEqual(text(.unlockCalibration), "Battery calibrated from your last 5 rides: about 8.4 Wh per 1%.")
    }

    /// Every catalogue type speaks at least once in the samples (so the wording guard covers all of them)
    func test_samples_coverEveryType() {
        let types = Set(InsightSamples.all().map(\.type))
        XCTAssertEqual(types, Set(InsightType.allCases))
    }

    // MARK: P-3 guard

    func test_noRewardLanguage_inAnyTemplate() throws {
        for i in InsightSamples.all() {
            XCTAssertEqual(InsightText.bannedIn(i.text), [], "P-3: \(i.type) says \(i.text)")
        }
        // every string literal of the template files, too (a template the samples miss is still checked)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CorckieCore/Insights")
        for file in ["InsightCatalogue.swift", "InsightRanking.swift", "InsightSamples.swift"] {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            let regex = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
            let ns = source as NSString
            var literals = 0
            for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let lit = ns.substring(with: m.range)
                literals += 1
                XCTAssertEqual(InsightText.bannedIn(lit), [], "P-3: \(file) has \(lit)")
            }
            XCTAssertGreaterThan(literals, 5, file)
        }
        // the guard itself works
        XCTAssertFalse(InsightText.bannedIn("New personal best on Home to Work").isEmpty)
        XCTAssertFalse(InsightText.bannedIn("5-day streak").isEmpty)
        XCTAssertFalse(InsightText.bannedIn("Great job!").isEmpty)
    }

    /// Shown numbers are honest (no 10% margin): Q19 / Q15 say the effect as measured
    func test_numbersShownAreHonest() {
        let pooled = [InsightSamples.effect("L1", "perKg", .used, 0.1, scope: .pooled)]
        let t = InsightCatalogue.q19After(rideId: "r", routeId: "A", loadKg: 10, loadLevel: nil, rideKm: 5, pooledEffects: pooled, nowMs: now)
        XCTAssertEqual(t.first?.text, "With a load (10 kg): +5% battery compared to usual (based on 6 loaded rides).")
    }

    // MARK: Gates (just below / at)

    func test_gate_Q1live_destinationGuess_T90() {
        // Monday 2026-06-29 08:00 local (+180) and the 4 Mondays before at 08:30
        let t = now
        let rides = (1...4).map { DestinationRide(routeId: "A", startPlaceId: "home", startAt: t - Int64($0) * 7 * day + 30 * 60_000, utcOffsetMin: 180) }
        XCTAssertNil(InsightCatalogue.destinationGuess(rides: Array(rides.prefix(3)), startPlaceId: "home", nowMs: t, utcOffsetMin: 180))
        XCTAssertEqual(InsightCatalogue.destinationGuess(rides: rides, startPlaceId: "home", nowMs: t, utcOffsetMin: 180)?.routeId, "A")
        XCTAssertNil(InsightCatalogue.destinationGuess(rides: rides, startPlaceId: "work", nowMs: t, utcOffsetMin: 180))
        // 61 min apart does not count
        let late = rides.map { r -> DestinationRide in var x = r; x.startAt += 31 * 60_000; return x }
        XCTAssertNil(InsightCatalogue.destinationGuess(rides: late, startPlaceId: "home", nowMs: t, utcOffsetMin: 180))
        // older than 60 days does not count
        let old = rides.map { r -> DestinationRide in var x = r; x.startAt -= 63 * day; return x }
        XCTAssertNil(InsightCatalogue.destinationGuess(rides: old, startPlaceId: "home", nowMs: t, utcOffsetMin: 180))
        // 70% top share: 7 of 10 yes, 6 of 9 no
        func mix(_ a: Int, _ b: Int) -> [DestinationRide] {
            (0..<(a + b)).map { i in DestinationRide(routeId: i < a ? "A" : "B", startPlaceId: "home", startAt: t - Int64(i + 1) * 7 * day % (56 * day) - Int64(i) * 60_000,
                                                     utcOffsetMin: 180) }
        }
        XCTAssertEqual(InsightCatalogue.destinationGuess(rides: mix(7, 3), startPlaceId: "home", nowMs: t, utcOffsetMin: 180)?.share ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertNil(InsightCatalogue.destinationGuess(rides: mix(6, 3), startPlaceId: "home", nowMs: t, utcOffsetMin: 180))
        // no guess, no Q1-live
        XCTAssertEqual(InsightCatalogue.q1Live(guess: nil, destination: "Work", variants: [], todayS: 600, rideId: nil, nowMs: t), [])
    }

    func test_gate_Q1after_T91_variantsAndOneMinute() {
        let a = v("v1", "A street", time: 960, n: 3)
        // the other way has 2 rides: progress only
        let below = InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v1", rideTimeS: 960, variants: [a, v("v2", "B street", time: 840, n: 2)], nowMs: now)
        XCTAssertEqual(below.count, 1)
        XCTAssertTrue(below[0].isProgress)
        XCTAssertEqual(below[0].text, "Comparing the ways: 2 of 3 rides via B street")
        // 3 rides each: it speaks
        let at = InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v1", rideTimeS: 960, variants: [a, v("v2", "B street", time: 840, n: 3)], nowMs: now)
        XCTAssertEqual(at.map(\.type), [.q1After])
        XCTAssertFalse(at[0].isProgress)
        // 59 s faster is not "faster"; 60 s is
        XCTAssertEqual(InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v1", rideTimeS: 960,
                                                  variants: [a, v("v2", "B street", time: 901, n: 3)], nowMs: now), [])
        XCTAssertEqual(InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v1", rideTimeS: 960,
                                                  variants: [a, v("v2", "B street", time: 900, n: 3)], nowMs: now).count, 1)
        // one variant only: nothing
        XCTAssertEqual(InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v1", rideTimeS: 960, variants: [a], nowMs: now), [])
    }

    func test_gate_Q2after_batteryNeedsFiveRidesEach() {
        let four = InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v1", rideTimeS: 960,
                                              variants: [v("v1", "A", time: 960, used: 9, n: 4), v("v2", "B", time: 840, used: 12, n: 4)], nowMs: now)
        XCTAssertFalse(four[0].text.contains("battery"))
        let five = InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v1", rideTimeS: 960,
                                              variants: [v("v1", "A", time: 960, used: 9, n: 5), v("v2", "B", time: 840, used: 12, n: 5)], nowMs: now)
        XCTAssertTrue(five[0].text.contains("but uses 3% more battery"))
        // on the fastest, the other uses 0.9 points less: nothing; 1 point: Q2
        XCTAssertEqual(InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v2", rideTimeS: 840,
                                                  variants: [v("v1", "A", time: 960, used: 11.1, n: 5), v("v2", "B", time: 840, used: 12, n: 5)], nowMs: now), [])
        XCTAssertEqual(InsightCatalogue.q1q2After(rideId: "r", routeId: "R", rideVariantId: "v2", rideTimeS: 840,
                                                  variants: [v("v1", "A", time: 960, used: 11, n: 5), v("v2", "B", time: 840, used: 12, n: 5)], nowMs: now).map(\.type), [.q2After])
    }

    func test_gate_Q2live_T92_decidesWithTheMargin() {
        let vs = [v("v1", "A", time: 960, used: 10, n: 5), v("v2", "B", time: 900, used: 8, n: 5)]
        // 20.5 - 10 = 10.5 would pass without the margin; with it (11) 9.5 < 10: the hint comes
        XCTAssertEqual(InsightCatalogue.q2Live(batteryPct: 20.5, plannedVariantId: "v1", variants: vs, routeId: "R", rideId: nil, nowMs: now).count, 1)
        XCTAssertEqual(InsightCatalogue.q2Live(batteryPct: 21.5, plannedVariantId: "v1", variants: vs, routeId: "R", rideId: nil, nowMs: now), [])
        // planned is already the most efficient: nothing
        XCTAssertEqual(InsightCatalogue.q2Live(batteryPct: 12, plannedVariantId: "v2", variants: vs, routeId: "R", rideId: nil, nowMs: now), [])
        // the shown battery is the honest reading
        XCTAssertEqual(InsightCatalogue.q2Live(batteryPct: 20.5, plannedVariantId: "v1", variants: vs, routeId: "R", rideId: nil, nowMs: now).first?.text,
                       "Battery 21%: take via B, it uses less.")
    }

    func test_gate_Q3_T93_threeRidesThenVerdictOnce() {
        func q3(_ option: [Double], _ other: [Double]) -> [Insight] {
            InsightCatalogue.q3(rideId: "r", routeId: "R", optionId: "o", optionName: "park shortcut", rideOptionTimeS: option.last ?? 0,
                                optionTimesS: option, otherTimesS: other, nowMs: now)
        }
        let two = q3([100, 100], [200, 200, 200])
        XCTAssertEqual(two.map(\.isProgress), [true])
        XCTAssertEqual(two.first?.text, "Park shortcut: 2 of 3 rides before a verdict")
        XCTAssertEqual(Set(q3([100, 100, 100], [200, 200, 200]).map(\.type)), [.q3After, .q3Verdict])
        XCTAssertEqual(q3([100, 100, 100, 100], [200, 200, 200]).map(\.type), [.q3After])
        // 19 s = no real difference, 20 s = saves
        XCTAssertTrue(q3([181, 181, 181], [200, 200, 200]).first { $0.type == .q3Verdict }?.text.contains("no real difference") == true)
        XCTAssertTrue(q3([180, 180, 180], [200, 200, 200]).first { $0.type == .q3Verdict }?.text.contains("saves about 20 s") == true)
    }

    func test_gate_Q4after_M14() {
        let r5 = UsualRangeValue(lo: 780, hi: 900, median: 840, n: 5, full: false)
        let r4 = UsualRangeValue(lo: 780, hi: 900, median: 840, n: 4, full: true)
        func q4(_ t: Double, _ r: UsualRangeValue) -> [Insight] {
            InsightCatalogue.q4After(rideId: "r", routeId: "R", rideTimeS: t, rideUsedPct: nil, usualTime: r, usualUsed: nil, explanation: nil, nowMs: now)
        }
        XCTAssertEqual(q4(1_000, r4), [], "fewer than 5 rides: never")
        XCTAssertEqual(q4(1_000, r5).count, 1)
        // T66: 2% of the edge (18 s) counts, 17 s does not
        XCTAssertEqual(q4(917, r5), [])
        XCTAssertEqual(q4(918, r5).count, 1)
        // causes only from the explanation (already past M15), same sign, largest first
        let ex = RideExplanation(items: [.init(factorId: "T1", level: "rush", timeS: 40, usedPct: nil, confidence: 0.7),
                                         .init(factorId: "W1", level: "tail", timeS: -30, usedPct: nil, confidence: 0.7),
                                         .init(factorId: "W1", level: "head", timeS: 90, usedPct: nil, confidence: 0.7)])
        let t = InsightCatalogue.q4After(rideId: "r", routeId: "R", rideTimeS: 1_000, rideUsedPct: nil, usualTime: r5, usualUsed: nil, explanation: ex, nowMs: now)
        XCTAssertEqual(t.first?.text, "2.5 min slower than usual: headwind (~1:30), rush hour (~40 s).")
    }

    func test_gate_Q4weekly_needsOneMinuteOrOnePercent() {
        let small = RideExplanation(items: [.init(factorId: "W1", level: "head", timeS: 59, usedPct: 0.9, confidence: 0.7)])
        XCTAssertEqual(InsightCatalogue.q4Weekly(weekStart: 0, explanations: [small], nowMs: now), [])
        let ok = RideExplanation(items: [.init(factorId: "W1", level: "head", timeS: 60, usedPct: 0.9, confidence: 0.7)])
        XCTAssertEqual(InsightCatalogue.q4Weekly(weekStart: 0, explanations: [ok], nowMs: now).first?.text,
                       "Biggest factor this week: headwind, which cost you ~1 min in total (based on 1 ride).")
    }

    func test_gate_Q9live_onlyWhenItDoesNotFit() {
        let fits = ThereAndBackModel(status: .fits, symbol: "", headline: "", detail: "", sparePct: 20, destination: "Work", batteryPct: 60)
        XCTAssertEqual(InsightCatalogue.q9Live(model: fits, routeId: "R", rideId: "r", basedOnN: 5, nowMs: now), [])
        var tight = fits
        tight.status = .tight
        let t = InsightCatalogue.q9Live(model: tight, routeId: "R", rideId: "r", basedOnN: 5, nowMs: now)
        XCTAssertEqual(t.first?.text, "Battery 60%: just enough for Work and back.")
        XCTAssertEqual(t.first?.insightClass, .safety)
        XCTAssertEqual(t.first?.livePriority, .returnCheck)
        XCTAssertEqual(InsightCatalogue.q9Live(model: nil, routeId: "R", rideId: "r", basedOnN: 5, nowMs: now), [])
    }

    func test_gate_Q13after_nineRidesAndT96() {
        func rides(flat: Int, calm: Int, flatS: Double = 800, flatPct: Double = 10) -> [CapRide] {
            (0..<flat).map { _ in CapRide(timeAtMaxPct: 60, totalS: flatS, usedPct: flatPct) } + (0..<calm).map { _ in CapRide(timeAtMaxPct: 10, totalS: 900, usedPct: 10) }
        }
        XCTAssertEqual(InsightCatalogue.q13After(rideId: "r", routeId: "R", routeName: nil, rides: [], nowMs: now), [], "no time-at-max data: nothing")
        XCTAssertEqual(InsightCatalogue.q13After(rideId: "r", routeId: "R", routeName: nil, rides: rides(flat: 4, calm: 4), nowMs: now).map(\.isProgress), [true])
        XCTAssertEqual(InsightCatalogue.q13After(rideId: "r", routeId: "R", routeName: nil, rides: rides(flat: 7, calm: 2), nowMs: now).first?.text,
                       "Speed cap on this route: 3 of 3 flat-out rides, 2 of 3 calmer rides")
        let at = InsightCatalogue.q13After(rideId: "r", routeId: "R", routeName: nil, rides: rides(flat: 5, calm: 4), nowMs: now)
        XCTAssertEqual(at.map(\.isProgress), [false])
        // T96: 59 s saved and 1.9% cost = not noteworthy
        XCTAssertEqual(InsightCatalogue.q13After(rideId: "r", routeId: "R", routeName: nil, rides: rides(flat: 5, calm: 5, flatS: 841, flatPct: 11.9), nowMs: now), [])
        XCTAssertEqual(InsightCatalogue.q13After(rideId: "r", routeId: "R", routeName: nil, rides: rides(flat: 5, calm: 5, flatS: 840), nowMs: now).count, 1)
        XCTAssertEqual(InsightCatalogue.q13After(rideId: "r", routeId: "R", routeName: nil, rides: rides(flat: 5, calm: 5, flatS: 900, flatPct: 12), nowMs: now).count, 1)
    }

    func test_gate_Q13weekly_threeRides() {
        let r = WeekRide(startAt: now, utcOffsetMin: 0, kind: "ride", distanceM: 5_000, totalS: 900, timeAtMaxPct: 40)
        XCTAssertEqual(InsightCatalogue.q13Weekly(weekStart: 0, rides: [r, r], capKmh: nil, savedS: nil, costPct: nil, nowMs: now), [])
        XCTAssertEqual(InsightCatalogue.q13Weekly(weekStart: 0, rides: [r, r, r], capKmh: nil, savedS: nil, costPct: nil, nowMs: now).first?.text,
                       "You rode at the speed cap 40% of the time this week.")
    }

    func test_gate_Q15live_T94() {
        let e = [InsightSamples.effect("W1", "head", .time, 90)]
        XCTAssertEqual(InsightCatalogue.q15Live(routeId: "R", routeName: nil, forecastHeadwindKmh: 15, routeEffects: e, rideId: nil, nowMs: now), [])
        XCTAssertEqual(InsightCatalogue.q15Live(routeId: "R", routeName: nil, forecastHeadwindKmh: 15.1, routeEffects: e, rideId: nil, nowMs: now).count, 1)
        let notYet = [InsightSamples.effect("W1", "head", .time, nil, n: 2)]
        XCTAssertEqual(InsightCatalogue.q15Live(routeId: "R", routeName: nil, forecastHeadwindKmh: 25, routeEffects: notYet, rideId: nil, nowMs: now), [],
                       "no live progress line")
        XCTAssertEqual(InsightCatalogue.q15Live(routeId: "R", routeName: nil, forecastHeadwindKmh: nil, routeEffects: e, rideId: nil, nowMs: now), [])
    }

    func test_gate_Q15after_oneMinuteOrOnePercent() {
        let route = [InsightSamples.effect("W1", "head", .time, 59)]
        func after(_ t: Double, _ u: Double) -> [Insight] {
            InsightCatalogue.q15After(rideId: "r", routeId: "R", routeName: nil, rideHeadwindKmh: 12,
                                      explanation: RideExplanation(items: [.init(factorId: "W1", level: "head", timeS: t, usedPct: u, confidence: 0.6)]),
                                      routeEffects: route, nowMs: now)
        }
        XCTAssertEqual(after(59, 0.9), [])
        XCTAssertEqual(after(60, 0).first?.text, "Headwind cost you ~1 min today.")
        XCTAssertEqual(after(20, 1).first?.text, "Headwind cost you ~20 s and ~1% battery today.")
        // a calm ride gets no progress line
        XCTAssertEqual(InsightCatalogue.q15After(rideId: "r", routeId: "R", routeName: nil, rideHeadwindKmh: 2, explanation: nil,
                                                 routeEffects: [InsightSamples.effect("W1", "head", .time, nil, n: 1)], nowMs: now), [])
        // the calm side is short: "1 of 3 calm rides"
        XCTAssertEqual(InsightCatalogue.q15After(rideId: "r", routeId: "R", routeName: "Home to Work", rideHeadwindKmh: 9, explanation: nil,
                                                 routeEffects: [InsightSamples.effect("W1", "head", .time, nil, n: 4, nWithout: 1)], nowMs: now).first?.text,
                       "Headwind on Home to Work: 1 of 3 calm rides")
    }

    func test_gate_Q15notify_9_4() {
        let pooled = [InsightSamples.effect("W1", "head", .time, 10, scope: .pooled)]
        func notify(soon: Bool = true, _ hw: Double, prev: Double? = nil) -> [Insight] {
            InsightCatalogue.q15Notify(routeId: "R", routeName: nil, routeKm: 5, likelyRideSoon: soon, forecastHeadwindKmh: hw, previousForecastKmh: prev,
                                       pooledEffects: pooled, rangeKm: nil, usualPctPerKm: nil, nowMs: now)
        }
        XCTAssertEqual(notify(soon: false, 25), [])
        XCTAssertEqual(notify(14.9), [])
        XCTAssertEqual(notify(15).count, 1)
        XCTAssertEqual(notify(14, prev: 4.1), [])
        XCTAssertEqual(notify(14, prev: 4).count, 1)
        // once a day: the same id all day, a new one tomorrow
        XCTAssertEqual(notify(15).first?.id, notify(15).first?.id)
        let tomorrow = InsightCatalogue.q15Notify(routeId: "R", routeName: nil, routeKm: 5, likelyRideSoon: true, forecastHeadwindKmh: 15, previousForecastKmh: nil,
                                                  pooledEffects: pooled, rangeKm: nil, usualPctPerKm: nil, nowMs: now + day)
        XCTAssertNotEqual(notify(15).first?.id, tomorrow.first?.id)
    }

    func test_gate_Q17_onceperClimb() {
        let a = InsightCatalogue.q17New(rideId: "r1", routeId: "R", climbId: "c1", climbName: nil, gainM: 12.4, nowMs: now)
        let b = InsightCatalogue.q17New(rideId: "r2", routeId: "R", climbId: "c1", climbName: nil, gainM: 12.4, nowMs: now + day)
        XCTAssertEqual(a.first?.text, "New climb detected: (+12 m). We'll track what it costs you.")
        XCTAssertEqual(a.first?.id, b.first?.id, "once per climb")
    }

    func test_gate_Q18_eightMetresAndLonger() {
        let steep = v("v1", "hill", time: 900, used: 10, n: 5, gain: 20, dist: 5_000)
        XCTAssertEqual(InsightCatalogue.q18(rideId: "r", routeId: "R", variants: [steep, v("v2", "park", time: 960, used: 9, n: 5, gain: 12.1, dist: 5_800)], nowMs: now), [])
        let at = InsightCatalogue.q18(rideId: "r", routeId: "R", variants: [steep, v("v2", "park", time: 960, used: 9, n: 5, gain: 12, dist: 5_800)], nowMs: now)
        XCTAssertEqual(at.first?.text, "Via park (flatter): +0.8 km, 8 m less climbing → \u{2212}1% battery, +1:00. Worth it when battery is low.")
        // the flatter one is shorter: not the Q18 trade-off
        XCTAssertEqual(InsightCatalogue.q18(rideId: "r", routeId: "R", variants: [steep, v("v2", "park", time: 960, used: 9, n: 5, gain: 2, dist: 4_800)], nowMs: now), [])
        // 2 rides on one: nothing
        XCTAssertEqual(InsightCatalogue.q18(rideId: "r", routeId: "R", variants: [steep, v("v2", "park", time: 960, used: 9, n: 2, gain: 2, dist: 5_800)], nowMs: now), [])
    }

    func test_gate_Q19_loadedOnly_progressThenText() {
        let notYet = [InsightSamples.effect("L1", "perKg", .used, nil, n: 4, nWithout: 30, scope: .pooled)]
        XCTAssertEqual(InsightCatalogue.q19After(rideId: "r", routeId: "R", loadKg: 0, loadLevel: nil, rideKm: 5, pooledEffects: notYet, nowMs: now), [])
        XCTAssertEqual(InsightCatalogue.q19After(rideId: "r", routeId: "R", loadKg: 5, loadLevel: "light", rideKm: 5, pooledEffects: notYet, nowMs: now).first?.text,
                       "Load: 4 of 5 loaded rides")
        let passed = [InsightSamples.effect("L1", "perKg", .used, 0.02, n: 5, scope: .pooled)]
        let t = InsightCatalogue.q19After(rideId: "r", routeId: "R", loadKg: 5, loadLevel: "light", rideKm: 5, pooledEffects: passed, nowMs: now)
        XCTAssertEqual(t.first?.text, "With a load (Light): +0.5% battery compared to usual (based on 5 loaded rides).")
        XCTAssertEqual(t.first?.insightClass, .surprise)
    }

    func test_gate_Q22_twoRidingDays_C22() {
        let a = WeekRide(startAt: now, utcOffsetMin: 180, kind: "ride", distanceM: 5_000, totalS: 900)
        var b = a
        b.startAt += 2 * 3_600_000
        XCTAssertEqual(InsightCatalogue.q22Weekly(weekStart: 0, rides: [a, b], previousWeekKm: nil, nowMs: now), [], "one riding day: skipped")
        b.startAt += day
        XCTAssertEqual(InsightCatalogue.q22Weekly(weekStart: 0, rides: [a, b], previousWeekKm: nil, nowMs: now).first?.text, "Last week: 10 km · 2 rides · 30 min")
        XCTAssertEqual(InsightCatalogue.q22Weekly(weekStart: 0, rides: [a, b], previousWeekKm: 20, nowMs: now).first?.text,
                       "Last week: 10 km · 2 rides · 30 min · ▼ 50% less than the week before")
    }

    func test_gate_firstAndUnlock_onceAtTheirCount() {
        func f(real: Int, route: Int, battery: Int, cal: Bool = false) -> [InsightType] {
            InsightCatalogue.firstAndUnlock(rideId: "r", realRides: real, routeId: "R", routeName: nil, routeRides: route, routeBatteryRides: battery,
                                            calibratedNow: cal, whPerPct: nil, firstRangeKm: nil, nowMs: now).map(\.type)
        }
        XCTAssertEqual(f(real: 1, route: 1, battery: 1), [.firstRide])
        XCTAssertEqual(f(real: 2, route: 2, battery: 2), [])
        XCTAssertEqual(f(real: 3, route: 3, battery: 3), [.unlockTime])
        XCTAssertEqual(f(real: 4, route: 4, battery: 4), [])
        XCTAssertEqual(f(real: 5, route: 5, battery: 5, cal: true), [.unlockBattery, .unlockCalibration])
        XCTAssertEqual(f(real: 6, route: 6, battery: 6), [])
    }

    func test_weekStart_isSundayMidnightLocal() {
        // 2026-06-01 00:00 UTC is a Monday; local +180: Monday 03:00 → week starts Sunday 2026-05-31 00:00 local = 05-30 21:00 UTC
        let ws = InsightWeek.start(ms: FactorSamples.t0, utcOffsetMin: 180)
        XCTAssertEqual(ws, FactorSamples.t0 - day - 3 * 3_600_000)
        XCTAssertEqual(DayClock.weekday(startAtMs: ws, utcOffsetMin: 180), 0)
        XCTAssertEqual(InsightWeek.start(ms: ws, utcOffsetMin: 180), ws)
        XCTAssertEqual(InsightWeek.start(ms: ws - 1, utcOffsetMin: 180), ws - 7 * day)
    }
}
