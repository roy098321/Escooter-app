import XCTest
@testable import CorckieCore

/// M2-03 / M2-04: usual ranges (M13), noticeably different (M14), rush hour (M18), Today (M26) with the 10% margin kept apart
/// (T101), and the route card model.
final class RouteStatsTests: XCTestCase {
    /// 20_717 days after 1970-01-01 is a Monday (weekday 1)
    static let monday: Int64 = 20_717
    static let day: Int64 = 86_400_000
    static let now: Int64 = monday * day + 12 * 3_600_000

    private func stat(_ id: String, daysAgo: Int, minute: Int = 480, timeS: Double? = 1_000, used: Double? = nil, dist: Double? = 3_700,
                      gain: Double? = nil, loss: Double? = nil, variant: String? = nil, excluded: Bool = false) -> RouteRideStats {
        RouteRideStats(rideId: id, startAt: (Self.monday - Int64(daysAgo)) * Self.day + Int64(minute) * 60_000, utcOffsetMin: 0,
                       variantId: variant, totalS: timeS, distanceM: dist, avgMovingMps: 7, usedPct: used, elevGainM: gain,
                       elevLossM: loss, excluded: excluded)
    }

    // MARK: DayClock (M18, M19)

    func test_dayClock_weekdayAndRushHour() {
        func ms(day: Int64, minute: Int) -> Int64 { day * Self.day + Int64(minute) * 60_000 }
        XCTAssertEqual(DayClock.weekday(startAtMs: ms(day: 20_717, minute: 0), utcOffsetMin: 0), 1)       // Monday
        XCTAssertEqual(DayClock.weekday(startAtMs: ms(day: 20_716, minute: 0), utcOffsetMin: 0), 0)       // Sunday
        XCTAssertEqual(DayClock.weekday(startAtMs: ms(day: 20_721, minute: 0), utcOffsetMin: 0), 5)       // Friday
        XCTAssertEqual(DayClock.weekday(startAtMs: ms(day: 20_722, minute: 0), utcOffsetMin: 0), 6)       // Saturday
        XCTAssertFalse(DayClock.isRushHour(weekday: 1, minuteOfDay: 6 * 60 + 59))
        XCTAssertTrue(DayClock.isRushHour(weekday: 1, minuteOfDay: 7 * 60))
        XCTAssertTrue(DayClock.isRushHour(weekday: 1, minuteOfDay: 9 * 60 + 30))
        XCTAssertFalse(DayClock.isRushHour(weekday: 1, minuteOfDay: 9 * 60 + 31))
        XCTAssertTrue(DayClock.isRushHour(weekday: 1, minuteOfDay: 16 * 60))
        XCTAssertTrue(DayClock.isRushHour(weekday: 1, minuteOfDay: 19 * 60))
        XCTAssertFalse(DayClock.isRushHour(weekday: 1, minuteOfDay: 19 * 60 + 1))
        XCTAssertTrue(DayClock.isRushHour(weekday: 0, minuteOfDay: 8 * 60), "Sunday is a workday in Israel")
        XCTAssertFalse(DayClock.isRushHour(weekday: 5, minuteOfDay: 8 * 60), "Friday is not")
        XCTAssertFalse(DayClock.isRushHour(weekday: 6, minuteOfDay: 8 * 60))
        // the ride's own UTC offset decides: 05:00 UTC at +02:00 is 07:00 local
        XCTAssertTrue(DayClock.isRushHour(startAtMs: ms(day: 20_717, minute: 5 * 60), utcOffsetMin: 120))
        XCTAssertFalse(DayClock.isRushHour(startAtMs: ms(day: 20_717, minute: 5 * 60), utcOffsetMin: 0))
        XCTAssertEqual(DayClock.dayType(weekday: 3), "workday")
        XCTAssertEqual(DayClock.dayType(weekday: 5), "friday")
        XCTAssertEqual(DayClock.dayType(weekday: 6), "saturday")
        XCTAssertEqual(DayClock.clockText(minuteOfDay: 8 * 60 + 56), "8:56")
        // late evening UTC is already tomorrow at +03:00
        XCTAssertEqual(DayClock.weekday(startAtMs: ms(day: 20_717, minute: 22 * 60), utcOffsetMin: 180), 2)
    }

    func test_T101_margin_isOnlyForDecisions() {
        XCTAssertEqual(SafetyMargin.factor, 1.10, accuracy: 1e-9)
        XCTAssertEqual(SafetyMargin.forDecision(10), 11, accuracy: 1e-9)
        XCTAssertEqual(SafetyMargin.forDecision(0), 0)
    }

    // MARK: M13 usual range

    func test_M13_percentiles_middle80() throws {
        let r = try XCTUnwrap(UsualRange.range([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
        XCTAssertEqual(r.lo, 1.9, accuracy: 1e-9)
        XCTAssertEqual(r.hi, 9.1, accuracy: 1e-9)
        XCTAssertEqual(r.median, 5.5, accuracy: 1e-9)
        XCTAssertEqual(r.n, 10)
        XCTAssertFalse(r.full)
        let five = try XCTUnwrap(UsualRange.range([10, 20, 30, 40, 50]))
        XCTAssertFalse(five.full, "5 rides is enough for the middle 80%")
        XCTAssertEqual(five.lo, 14, accuracy: 1e-9)
        XCTAssertEqual(five.hi, 46, accuracy: 1e-9)
        XCTAssertNil(UsualRange.range([]))
    }

    func test_M13_underFiveRides_isMinToMax() throws {
        let r = try XCTUnwrap(UsualRange.range([30, 10, 20]))
        XCTAssertTrue(r.full)
        XCTAssertEqual(r.lo, 10)
        XCTAssertEqual(r.hi, 30)
        XCTAssertEqual(r.median, 20)
        let one = try XCTUnwrap(UsualRange.range([7]))
        XCTAssertEqual(one.lo, 7)
        XCTAssertEqual(one.hi, 7)
    }

    func test_M13_window_is90DaysNewest20_notExcluded() {
        var rides: [RouteRideStats] = []
        for i in 0..<30 { rides.append(stat("r\(i)", daysAgo: i + 1)) }              // 1...30 days ago
        rides.append(stat("old", daysAgo: 91))
        rides.append(stat("excl", daysAgo: 0, excluded: true))
        let sel = UsualRange.select(rides, nowMs: Self.now)
        XCTAssertEqual(sel.count, 20)
        XCTAssertEqual(sel.first?.rideId, "r0", "newest first")
        XCTAssertEqual(sel.last?.rideId, "r19")
        XCTAssertFalse(sel.contains { $0.rideId == "old" || $0.rideId == "excl" })
        // only the old one: nothing left
        XCTAssertTrue(UsualRange.select([stat("old", daysAgo: 91)], nowMs: Self.now).isEmpty)
        XCTAssertEqual(UsualRange.select([stat("edge", daysAgo: 89)], nowMs: Self.now).count, 1)
    }

    func test_T67_gates_timeNeeds3_batteryNeeds5() {
        let three = (0..<3).map { stat("t\($0)", daysAgo: $0 + 1, used: 10) }
        XCTAssertNotNil(UsualRange.range(of: .time, rides: three))
        XCTAssertNil(UsualRange.range(of: .time, rides: Array(three.prefix(2))))
        XCTAssertNil(UsualRange.range(of: .battery, rides: three))
        let five = (0..<5).map { stat("f\($0)", daysAgo: $0 + 1, used: 10) }
        XCTAssertNotNil(UsualRange.range(of: .battery, rides: five))
        XCTAssertNotNil(UsualRange.range(of: .batteryPerKm, rides: five))
        XCTAssertEqual(UsualRange.progress(of: .battery, rides: three).have, 3)
        XCTAssertEqual(UsualRange.progress(of: .battery, rides: three).need, 5)
        // battery per km needs a ride of at least 1 km
        XCTAssertNil(stat("s", daysAgo: 1, used: 5, dist: 800).pctPerKm)
        XCTAssertEqual(stat("s", daysAgo: 1, used: 6, dist: 3_000).pctPerKm ?? 0, 2, accuracy: 1e-9)
    }

    func test_T65_split_whenRushHourSeparatesTheRides() {
        var rides: [RouteRideStats] = []
        for i in 0..<4 { rides.append(stat("rush\(i)", daysAgo: 7 * (i + 1), minute: 8 * 60, timeS: 1_500 + Double(i) * 30)) }   // Mondays 08:00
        for i in 0..<4 { rides.append(stat("calm\(i)", daysAgo: 7 * (i + 1), minute: 11 * 60, timeS: 800 + Double(i) * 20)) }  // Mondays 11:00
        let split = UsualRange.timeSplit(rides)
        XCTAssertNotNil(split)
        XCTAssertEqual(split?.factor, "rush hour")
        XCTAssertGreaterThan(split?.with.median ?? 0, split?.without.median ?? 0)
        // similar times: no split
        var similar: [RouteRideStats] = []
        for i in 0..<4 { similar.append(stat("a\(i)", daysAgo: 7 * (i + 1), minute: 8 * 60, timeS: 1_000 + Double(i) * 10)) }
        for i in 0..<4 { similar.append(stat("b\(i)", daysAgo: 7 * (i + 1), minute: 11 * 60, timeS: 1_005 + Double(i) * 10)) }
        XCTAssertNil(UsualRange.timeSplit(similar))
        // a group of 2 is too small
        var small = rides.filter { $0.rideId.hasPrefix("rush") }
        small.append(stat("calm0", daysAgo: 7, minute: 11 * 60, timeS: 800))
        small.append(stat("calm1", daysAgo: 14, minute: 11 * 60, timeS: 820))
        XCTAssertNil(UsualRange.timeSplit(small))
    }

    func test_M14_noticeablyDifferent_edges() {
        let range = UsualRangeValue(lo: 720, hi: 900, median: 800, n: 10, full: false)
        let step = UsualRange.minimumTimeStepS
        XCTAssertEqual(UsualRange.noticeablyDifferent(value: 960, range: range, minimumStep: step), .above(by: 60))     // 60 s above the edge
        XCTAssertEqual(UsualRange.noticeablyDifferent(value: 905, range: range, minimumStep: step), .within)             // 5 s, under 1 min and 2%
        XCTAssertEqual(UsualRange.noticeablyDifferent(value: 920, range: range, minimumStep: step), .above(by: 20))     // 20 s but over 2% of 900 (18 s)
        XCTAssertEqual(UsualRange.noticeablyDifferent(value: 660, range: range, minimumStep: step), .below(by: 60))
        XCTAssertEqual(UsualRange.noticeablyDifferent(value: 800, range: range, minimumStep: step), .within)
        let few = UsualRangeValue(lo: 720, hi: 900, median: 800, n: 4, full: true)
        XCTAssertEqual(UsualRange.noticeablyDifferent(value: 2_000, range: few, minimumStep: step), .within, "under 5 rides it never says it")
        // battery: one percentage point
        let battery = UsualRangeValue(lo: 8, hi: 12, median: 10, n: 8, full: false)
        XCTAssertEqual(UsualRange.noticeablyDifferent(value: 13, range: battery, minimumStep: UsualRange.minimumBatteryStepPct), .above(by: 1))
        XCTAssertEqual(UsualRange.noticeablyDifferent(value: 12.2, range: battery, minimumStep: UsualRange.minimumBatteryStepPct), .within)
    }

    // MARK: M26 Today

    private func commuteRides() -> [RouteRideStats] {
        (0..<6).map { stat("c\($0)", daysAgo: 7 * ($0 + 1), minute: 8 * 60, timeS: 1_000 + Double($0) * 20, used: $0 < 2 ? 10 : ($0 < 4 ? 11 : 12)) }
    }

    func test_M26_today_isTheHonestMedian_andTheMarginIsSeparate() throws {
        guard case .estimate(let e) = TodayEstimator.estimate(rides: commuteRides(), nowMs: Self.now, utcOffsetMin: 0) else {
            return XCTFail("6 rides is enough")
        }
        XCTAssertEqual(e.timeS, 1_050, accuracy: 1e-9)
        XCTAssertNil(e.widerRangeS)
        XCTAssertEqual(e.usedPct ?? 0, 11, accuracy: 1e-9, "shown honest")
        XCTAssertEqual(e.neededPct ?? 0, 12.1, accuracy: 1e-9, "decisions use +10%")
        XCTAssertEqual(e.basedOn, 6)
        XCTAssertEqual(e.departureMinute, 480, "the usual departure on a workday")
        XCTAssertTrue(e.rushHour)
        XCTAssertFalse(e.factorsApplied)
    }

    func test_M26_arriveByDeparture_andFactorEffects() throws {
        guard case .estimate(let e) = TodayEstimator.estimate(rides: commuteRides(), nowMs: Self.now, utcOffsetMin: 0, departureMinute: 13 * 60,
                                                              timeEffectS: 120, usedEffectPct: 2) else { return XCTFail("estimate") }
        XCTAssertEqual(e.departureMinute, 13 * 60)
        XCTAssertFalse(e.rushHour)
        XCTAssertEqual(e.timeS, 1_170, accuracy: 1e-9)
        XCTAssertEqual(e.usedPct ?? 0, 13, accuracy: 1e-9)
        XCTAssertTrue(e.factorsApplied)
    }

    func test_M26_confirmationWidensTheRange_whenItDisagreesByMoreThanTheUsualWidth() throws {
        // the factors say +300 s but similar past rides say ~1050: the range (width 80) is wider than "~value"
        guard case .estimate(let e) = TodayEstimator.estimate(rides: commuteRides(), nowMs: Self.now, utcOffsetMin: 0, timeEffectS: 300) else {
            return XCTFail("estimate")
        }
        let w = try XCTUnwrap(e.widerRangeS)
        XCTAssertEqual(w.lowerBound, 1_010, accuracy: 1e-9)
        XCTAssertEqual(w.upperBound, 1_350, accuracy: 1e-9)
    }

    func test_M26_gates_noEstimateUnder3Rides_noBatteryUnder5() {
        let two = Array(commuteRides().prefix(2))
        XCTAssertEqual(TodayEstimator.estimate(rides: two, nowMs: Self.now, utcOffsetMin: 0), .notEnough(have: 2, need: 3))
        let excluded = commuteRides().map { r -> RouteRideStats in
            var x = r
            x.excluded = true
            return x
        }
        XCTAssertEqual(TodayEstimator.estimate(rides: excluded, nowMs: Self.now, utcOffsetMin: 0), .notEnough(have: 0, need: 3))
        guard case .estimate(let e) = TodayEstimator.estimate(rides: Array(commuteRides().prefix(4)), nowMs: Self.now, utcOffsetMin: 0) else {
            return XCTFail("4 rides give a time estimate")
        }
        XCTAssertNil(e.usedPct)
        XCTAssertNil(e.neededPct)
    }

    func test_M26_usesTheMatchingRushHourGroup_whenTheRangeSplits() throws {
        var rides: [RouteRideStats] = []
        for i in 0..<4 { rides.append(stat("rush\(i)", daysAgo: 7 * (i + 1), minute: 8 * 60, timeS: 1_500 + Double(i) * 30)) }
        for i in 0..<4 { rides.append(stat("calm\(i)", daysAgo: 7 * (i + 1), minute: 11 * 60, timeS: 800 + Double(i) * 20)) }
        guard case .estimate(let rush) = TodayEstimator.estimate(rides: rides, nowMs: Self.now, utcOffsetMin: 0, departureMinute: 8 * 60),
              case .estimate(let calm) = TodayEstimator.estimate(rides: rides, nowMs: Self.now, utcOffsetMin: 0, departureMinute: 11 * 60) else {
            return XCTFail("estimates")
        }
        XCTAssertEqual(rush.timeS, 1_545, accuracy: 1e-9)
        XCTAssertEqual(calm.timeS, 830, accuracy: 1e-9)
    }

    // MARK: Route card

    private func cardInput(rides: [RouteRideStats], variants: [VariantInfo] = [], from: String? = "Home", to: String? = "Work",
                           custom: String? = nil, ordinal: Int = 1, state: RouteState = .saved) -> RouteCardInput {
        RouteCardInput(routeId: "R", customName: custom, fromName: from, toName: to, ordinal: ordinal, state: state, variants: variants,
                       rides: rides, nowMs: Self.now, utcOffsetMin: 0)
    }

    private let line = [GeoPoint(lat: 10, lon: -30), GeoPoint(lat: 10.01, lon: -30)]

    func test_routeCard_fullRoute_hasEverySection() throws {
        var rides: [RouteRideStats] = []
        for i in 0..<6 {
            rides.append(stat("r\(i)", daysAgo: 7 * (i + 1), minute: 8 * 60, timeS: 1_000 + Double(i) * 20, used: 10 + Double(i % 2), gain: 40, loss: 38,
                              variant: i < 4 ? "v1" : "v2"))
        }
        let variants = [VariantInfo(id: "v1", routeId: "R", name: "via Herzl", path: line, isReference: true),
                        VariantInfo(id: "v2", routeId: "R", name: "Variant 2", path: line)]
        let card = RouteCardBuilder.build(cardInput(rides: rides, variants: variants))
        XCTAssertEqual(card.title, "Home \u{2192} Work")
        XCTAssertEqual(card.subtitle, "Saved route \u{00B7} based on 6 rides")
        XCTAssertTrue(card.saved)
        XCTAssertEqual(card.stats.map { $0.label }, ["Time", "Distance", "Avg. speed", "Battery", "Battery / km", "Elevation"])
        XCTAssertTrue(card.stats.allSatisfy { !$0.filling }, "6 rides meet both gates")
        XCTAssertEqual(card.stats[0].value, "17\u{2013}18 min")
        XCTAssertEqual(card.stats[1].value, "~3.7 km")
        XCTAssertEqual(card.stats[5].value, "~+40 m")
        XCTAssertFalse(card.today.filling)
        XCTAssertTrue(card.today.headline.hasPrefix("Today: ~"), card.today.headline)
        XCTAssertTrue(card.today.detail.contains("Based on 6 rides"), card.today.detail)
        XCTAssertTrue(card.today.detail.contains("leaving 8:00"), card.today.detail)
        XCTAssertEqual(card.variants.count, 2)
        XCTAssertTrue(card.variants[0].isReference)
        XCTAssertEqual(card.variants[0].rides, 4)
        XCTAssertEqual(card.variants[1].timeText, "2 rides", "a variant with under 3 rides shows only how many")
        let elevation = try XCTUnwrap(card.elevation)
        XCTAssertTrue(elevation.thisWay.hasPrefix("Home \u{2192} Work: ~+40 m / \u{2212}38 m"), elevation.thisWay)
        XCTAssertTrue(elevation.otherIsEstimate)
        XCTAssertTrue(elevation.otherWay.contains("Work \u{2192} Home: ~+38 m / \u{2212}40 m"), elevation.otherWay)
        XCTAssertTrue(elevation.otherWay.contains("(estimate)"))
        XCTAssertEqual(card.rides.count, 5)
        XCTAssertEqual(card.totalRides, 6)
        XCTAssertEqual(card.rides[0].rideId, "r0", "newest first")
        XCTAssertEqual(card.trendMin.count, 6)
        XCTAssertEqual(card.map.count, 2)
        XCTAssertFalse(card.map[0].dashed)
        XCTAssertTrue(card.map[1].dashed)
    }

    func test_routeCard_otherDirectionWithRides_isNotAnEstimate() throws {
        let rides = (0..<4).map { stat("r\($0)", daysAgo: $0 + 1, gain: 40, loss: 38) }
        let back = (0..<3).map { stat("b\($0)", daysAgo: $0 + 1, gain: 36, loss: 41) }
        var input = cardInput(rides: rides)
        input.otherDirection = back
        let e = try XCTUnwrap(RouteCardBuilder.build(input).elevation)
        XCTAssertFalse(e.otherIsEstimate)
        XCTAssertTrue(e.otherWay.contains("~+36 m / \u{2212}41 m"), e.otherWay)
        XCTAssertFalse(e.otherWay.contains("estimate"))
    }

    func test_routeCard_sparseRoute_hidesEmptySections_andSaysHowFarItIs() {
        let rides = [stat("a", daysAgo: 2, timeS: 900), stat("b", daysAgo: 1, timeS: 960)]
        let card = RouteCardBuilder.build(cardInput(rides: rides, variants: [VariantInfo(id: "v", routeId: "R", name: "Variant 1", path: line, isReference: true)],
                                                    state: .suggested))
        XCTAssertEqual(card.subtitle, "Suggested route \u{00B7} based on 2 rides")
        XCTAssertFalse(card.saved)
        XCTAssertEqual(card.stats.count, 5, "elevation has no data at all: hidden")
        XCTAssertEqual(card.stats[0].value, "2 of 3 rides")
        XCTAssertTrue(card.stats[0].filling)
        XCTAssertEqual(card.stats[3].value, "0 of 5 rides")
        XCTAssertTrue(card.today.filling)
        XCTAssertEqual(card.today.detail, "2 of 3 rides so far")
        XCTAssertTrue(card.variants.isEmpty, "one variant: no variants section")
        XCTAssertNil(card.elevation)
        XCTAssertEqual(card.rides.count, 2)
        XCTAssertEqual(card.map.count, 1)
    }

    func test_routeCard_underFiveRides_saysBasedOnN() {
        let rides = (0..<3).map { stat("r\($0)", daysAgo: $0 + 1, timeS: 900 + Double($0) * 60) }
        let card = RouteCardBuilder.build(cardInput(rides: rides))
        XCTAssertEqual(card.stats[0].value, "15\u{2013}17 min")
        XCTAssertEqual(card.stats[0].note, "based on 3 rides")
    }

    func test_routeCard_splitLine_underTheTimeStat() throws {
        var rides: [RouteRideStats] = []
        for i in 0..<4 { rides.append(stat("rush\(i)", daysAgo: 7 * (i + 1), minute: 8 * 60, timeS: 1_500 + Double(i) * 30)) }
        for i in 0..<4 { rides.append(stat("calm\(i)", daysAgo: 7 * (i + 1), minute: 11 * 60, timeS: 800 + Double(i) * 20)) }
        let note = try XCTUnwrap(RouteCardBuilder.build(cardInput(rides: rides)).stats[0].note)
        XCTAssertTrue(note.hasPrefix("Rush hour "), note)
        XCTAssertTrue(note.contains("otherwise"), note)
    }

    func test_routeLabels_nameFallbacks() {
        XCTAssertEqual(RouteLabels.title(customName: "Commute", fromName: "A", toName: "B", ordinal: 2), "Commute")
        XCTAssertEqual(RouteLabels.title(customName: "  ", fromName: "Home", toName: "Work", ordinal: 2), "Home \u{2192} Work")
        XCTAssertEqual(RouteLabels.title(customName: nil, fromName: nil, toName: "Work", ordinal: 3), "Route 3")
        XCTAssertEqual(RouteLabels.place(nil), "Unnamed place")
        XCTAssertEqual(RouteLabels.place(""), "Unnamed place")
    }

    func test_rangeText_formats() {
        func r(_ lo: Double, _ hi: Double) -> UsualRangeValue { UsualRangeValue(lo: lo, hi: hi, median: (lo + hi) / 2, n: 8, full: false) }
        XCTAssertEqual(RouteCardBuilder.rangeText(.time, r(720, 900)), "12\u{2013}15 min")
        XCTAssertEqual(RouteCardBuilder.rangeText(.time, r(780, 790)), "~13 min")
        XCTAssertEqual(RouteCardBuilder.rangeText(.time, r(3_600, 4_020)), "1 h 00 min \u{2013} 1 h 07 min")
        XCTAssertEqual(RouteCardBuilder.rangeText(.distance, r(8_300, 8_500)), "8.3\u{2013}8.5 km")
        XCTAssertEqual(RouteCardBuilder.rangeText(.avgSpeed, r(21, 24)), "21\u{2013}24 km/h")
        XCTAssertEqual(RouteCardBuilder.rangeText(.battery, r(9.2, 11.8)), "9\u{2013}12%")
        XCTAssertEqual(RouteCardBuilder.rangeText(.batteryPerKm, r(1.14, 1.31)), "1.1\u{2013}1.3%/km")
        XCTAssertEqual(RouteCardBuilder.rangeText(.elevation, r(30, 45)), "~+30\u{2013}45 m")
    }
}

final class RouteOfferTests: XCTestCase {
    func test_offer_suggestedAfterTwoTrips_savedLine_andNothingWhenDismissed() throws {
        let two = try XCTUnwrap(RouteOfferModel.make(routeId: "R", state: .suggested, title: "Route 1", ridesOnRoute: 2))
        XCTAssertFalse(two.saved)
        XCTAssertEqual(two.headline, "Save as route?")
        XCTAssertTrue(two.detail.contains("twice"), two.detail)
        let four = try XCTUnwrap(RouteOfferModel.make(routeId: "R", state: .suggested, title: "Route 1", ridesOnRoute: 4))
        XCTAssertTrue(four.detail.contains("4 times"), four.detail)
        let saved = try XCTUnwrap(RouteOfferModel.make(routeId: "R", state: .saved, title: "Home \u{2192} Work", ridesOnRoute: 7))
        XCTAssertTrue(saved.saved)
        XCTAssertEqual(saved.headline, "Route \u{00B7} Home \u{2192} Work")
        XCTAssertNil(RouteOfferModel.make(routeId: "R", state: .dismissed, title: "x", ridesOnRoute: 3))
        // P-3: nothing that sounds like a reward
        for text in [two.detail, four.detail, saved.detail] {
            for word in ["record", "best", "streak", "badge", "goal"] { XCTAssertFalse(text.lowercased().contains(word), text) }
        }
    }
}
