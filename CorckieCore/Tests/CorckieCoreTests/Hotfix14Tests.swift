@testable import CorckieCore
import XCTest

/// Hotfix .14 (owner 26-27 Nov): one savings rule (B114), saved per km over the last 30 days, cargo options. Synthetic numbers only.
final class Hotfix14Tests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    private let day: Int64 = 86_400_000
    private let t0: Int64 = 1_790_000_000_000

    private func prices(_ fuel: [PricePoint] = [PricePoint(validFrom: "2026-01-01", value: 7.0)]) -> StatsPrices {
        StatsPrices(packWh: 1260, fuelLPer100km: 7, fuelHistory: PriceHistory(fuel),
                    electricityHistory: PriceHistory([PricePoint(validFrom: "2000-01-01", value: 0.64)]))
    }

    private func ride(_ d: Int, km: Double, kind: String = "ride", used: Double? = 10) -> StatsRide {
        StatsRide(startAt: t0 + Int64(d) * day, utcOffsetMin: 120, kind: kind, distanceM: km * 1000, totalS: km * 120, usedPct: used)
    }

    func test_B114_theRuleIsTheStatsPeriodsOwn() {
        let rides = [ride(0, km: 14), ride(1, km: 1.5), ride(2, km: 9, kind: "shortHop"), ride(3, km: 20, used: nil), ride(4, km: 30)]
        let p = prices()
        let period = StatsCalc.period(span: .month, mode: .calendar, nowMs: t0 + 4 * day, utcOffsetMin: 120)
        let inPeriod = rides.filter { $0.startAt >= period.startMs && $0.startAt < period.endMs }
        let byStats = StatsCalc.totals(inPeriod, period: period, prices: p, utcOffsetMin: 120).fuelSavedIls ?? -1
        XCTAssertEqual(SavingsRule.total(inPeriod, prices: p).savedIls, byStats, accuracy: 1e-9, "the same money as the Stats period")
    }

    func test_B114_aPeriodNeverShowsMoreThanTheLifetime() {
        let rides = (0..<60).map { ride($0, km: Double(5 + $0 % 9), used: Double(4 + $0 % 5)) }
        let p = prices()
        let life = SavingsRule.total(rides, prices: p).savedIls
        var weeks = 0.0
        var k = 0
        while k < rides.count {
            let w = SavingsRule.total(Array(rides[k..<min(k + 7, rides.count)]), prices: p).savedIls
            XCTAssertLessThanOrEqual(w, life + 1e-9)
            weeks += w
            k += 7
        }
        XCTAssertEqual(weeks, life, accuracy: 1e-6, "the weeks add up to the lifetime")
    }

    func test_shortHopsAndShortRidesSaveNothing() {
        let p = prices()
        XCTAssertEqual(SavingsRule.net(ride(0, km: 1.9), prices: p), 0)
        XCTAssertEqual(SavingsRule.net(ride(0, km: 9, kind: "shortHop"), prices: p), 0)
        XCTAssertEqual(SavingsRule.net(ride(0, km: 10, used: 0), prices: p) ?? 0, 10 * 0.07 * 7, accuracy: 1e-9)
        XCTAssertNil(SavingsRule.net(ride(0, km: 10), prices: StatsPrices(packWh: 1260)), "no fuel price: nothing to say")
    }

    func test_perKm_followsTheLast30Days() throws {
        // 200 km long ago at 6 ILS/L, then 100 km in the last 30 days at 8 ILS/L
        let old = (0..<20).map { ride($0, km: 10, used: 0) }
        let recent = (100..<110).map { ride($0, km: 10, used: 0) }
        let p = prices([PricePoint(validFrom: "2026-01-01", value: 6.0), PricePoint(validFrom: "2026-12-20", value: 8.0)])
        let now = t0 + 112 * day
        let all = old + recent
        let windowRides = SavingsRule.window(all, nowMs: now)
        XCTAssertEqual(windowRides.count, 10)
        let life = SavingsRule.total(all, prices: p)
        let v = try XCTUnwrap(SavedPerKmValue.make(window: SavingsRule.total(windowRides, prices: p), lifetimeSavedIls: life.savedIls, lifetimeKm: life.km))
        XCTAssertTrue(v.isWindow)
        XCTAssertEqual(v.label, "last 30 days")
        let lifetimePerKm = life.savedIls / life.km
        XCTAssertGreaterThan(v.perKm, lifetimePerKm, "today's higher price shows at once, not diluted by old km")
    }

    func test_perKm_fewKmInTheWindow_showsTheLifetime() throws {
        let rides = (0..<20).map { ride($0, km: 10, used: 0) } + [ride(100, km: 5, used: 0)]
        let p = prices()
        let w = SavingsRule.total(SavingsRule.window(rides, nowMs: t0 + 101 * day), prices: p)
        let life = SavingsRule.total(rides, prices: p)
        let v = try XCTUnwrap(SavedPerKmValue.make(window: w, lifetimeSavedIls: life.savedIls, lifetimeKm: life.km))
        XCTAssertFalse(v.isWindow)
        XCTAssertEqual(v.label, "lifetime")
    }

    func test_cargoIsUnloaded5kgOrCustom() throws {
        let home = try source("App/UI/Home/HomeView.swift")
        XCTAssertTrue(home.contains("(Self.loadNone, \"Unloaded\"), (Self.loadFive, \"5 kg\"), (Self.loadCustom, loadCustomLabel)"))
        XCTAssertFalse(home.contains("loadTen"), "10 kg is gone; a stored 10 kg shows as Custom 10")
    }

    // MARK: N12-6 Stats in three tabs

    func test_N12_6_perRide_realRidesOnly() throws {
        let rides = [ride(0, km: 10, used: 5), ride(1, km: 20, used: 9), ride(2, km: 1, kind: "shortHop")]
        var top = rides
        top[1].topSpeedMps = 73 / 3.6
        let r = try XCTUnwrap(PeriodRideStats.make(top))
        XCTAssertEqual(r.avgKm, 15, accuracy: 1e-9)
        XCTAssertEqual(r.longestKm, 20, accuracy: 1e-9)
        XCTAssertEqual(r.topKmh ?? 0, 73, accuracy: 1e-6)
        XCTAssertEqual(r.avgKmh ?? 0, 30, accuracy: 1e-6, "km ÷ time (120 s a km = 30 km/h)")
        XCTAssertNil(PeriodRideStats.make([ride(0, km: 1, kind: "shortHop")]))
    }

    func test_N12_6_energyInRealWorldTerms() throws {
        var t = StatsTotals()
        t.km = 100; t.charges = 0.5
        let e = try XCTUnwrap(PeriodEnergy.make(t, packWh: 1260))
        XCTAssertEqual(e.whPerKm, 6.3, accuracy: 1e-9)
        XCTAssertEqual(e.kmPerPct, 2, accuracy: 1e-9)
        XCTAssertEqual(e.rangeKm, 200, accuracy: 1e-9)
        XCTAssertEqual(e.kWh, 0.63, accuracy: 1e-9)
        XCTAssertNil(PeriodEnergy.make(StatsTotals(), packWh: 1260))
        let pts = RideEnergyPoint.last((0..<14).map { ride($0, km: 10, used: 2) } + [ride(20, km: 1.5)], packWh: 1260)
        XCTAssertEqual(pts.count, 10, "the last 10 rides over 2 km")
        XCTAssertEqual(pts.last?.whPerKm ?? 0, 2.52, accuracy: 1e-9)
    }

    func test_N12_6_runningTotalAndPaidOff() throws {
        let p = prices()
        let rides = (0..<40).map { ride($0, km: 10, used: 0) }
        let months = SavedByMonth.make(rides, prices: p, startIls: 5)
        XCTAssertGreaterThanOrEqual(months.count, 2)
        XCTAssertEqual(months.last?.cumulativeIls ?? 0, 5 + SavingsRule.total(rides, prices: p).savedIls, accuracy: 1e-6)
        XCTAssertNil(PaidOff.make(savedIls: 100, priceIls: nil), "only once a price is set")
        let paid = try XCTUnwrap(PaidOff.make(savedIls: 2_140, priceIls: 6_300))
        XCTAssertEqual(paid.pctText, "33%")
        XCTAssertEqual(PaidOff.make(savedIls: 9_000, priceIls: 6_300)?.fraction, 1)
    }

    func test_N12_6_statsHasThreeTabs_noTimeOfDay() throws {
        let stats = try source("App/UI/Stats/StatsView.swift")
        XCTAssertTrue(stats.contains("GlassSegmented(options: StatsTab.allCases.map"))
        for f in ["ridesTab(m)", "moneyTab(m)", "energyTab(m)"] { XCTAssertTrue(stats.contains(f), f) }
        XCTAssertEqual(StatsTab.allCases.map(\.title), ["Rides", "Money", "Energy"])
        for banned in ["hour of", "time of day", "mornings", "evenings"] {
            XCTAssertFalse(stats.lowercased().contains(banned), "no when-you-ride numbers: \(banned)")
        }
    }

    // MARK: N12-4 maintenance per scooter

    func test_N12_4_maintenancePerScooter() throws {
        let q = try source("App/Store/Queries/MaintenanceQueries.swift")
        XCTAssertTrue(q.contains("return try Self.rideKm(db)"), "no odometer: km from its own rides")
        let svc = try source("App/Notifier/MaintenanceService.swift")
        XCTAssertTrue(svc.contains("static func syncScooter(_ db: AppDatabase)"))
        XCTAssertTrue(svc.contains("static func rows(_ db: AppDatabase) -> [Row] {\n        syncScooter(db)"))
    }

    // MARK: N12-7 route card

    private func line(_ id: String, _ minutes: Double?, lat: Double) -> RouteMapLine {
        RouteMapLine(points: (0..<20).map { GeoPoint(lat: lat + Double($0) * 0.001, lon: -30) }, dashed: id != "a", variantId: id,
                     name: "Way \(id)", medianS: minutes.map { $0 * 60 })
    }

    func test_N12_7_fastestWayIsTheMainLine_othersShowMinutesBehind() {
        let plan = RouteMapPlan.make([line("a", 35, lat: 10), line("b", 31, lat: 10.1), line("c", 40, lat: 10.2)], combination: nil)
        let main = plan.ways.filter(\.isMain)
        XCTAssertEqual(main.map(\.variantId), ["b"], "the fastest way, not the usual one")
        XCTAssertEqual(main.first?.chip, "Fastest \u{00B7} 31 min")
        XCTAssertEqual(plan.ways.first { $0.variantId == "a" }?.chip, "+4 min")
        XCTAssertEqual(plan.ways.first { $0.variantId == "c" }?.chip, "+9 min")
        XCTAssertEqual(plan.ways.last?.isMain, true, "drawn last, on top")
        XCTAssertEqual(plan.arrows.count, 3, "direction arrows along the main line")
        XCTAssertEqual(plan.arrows.first?.bearingDeg ?? -1, 0, accuracy: 1e-6, "heading north")
    }

    func test_N12_7_combinationLeads_tappedWayLightsUp() {
        let lines = [line("a", 35, lat: 10), line("b", 31, lat: 10.1)]
        let combo = (0..<10).map { GeoPoint(lat: 11 + Double($0) * 0.001, lon: -30) }
        let withCombo = RouteMapPlan.make(lines, combination: combo)
        XCTAssertEqual(withCombo.ways.filter(\.isMain).count, 1)
        XCTAssertNil(withCombo.ways.last?.variantId, "the fastest combination is the main line")
        let tapped = RouteMapPlan.make(lines, combination: combo, selected: "a")
        XCTAssertEqual(tapped.ways.filter(\.isMain).map(\.variantId), ["a"])
        XCTAssertEqual(tapped.ways.last?.chip, "Way a \u{00B7} 35 min")
    }

    func test_N12_7_noDottedLines() throws {
        let card = try source("App/UI/Routes/RouteCardView.swift")
        XCTAssertFalse(card.contains("dash: l.dashed"), "no dotted ways")
        XCTAssertTrue(card.contains("RideCardScreen(detent: $cardDetent)"), "the card pulls down to the map")
        XCTAssertTrue(card.contains("Show the fastest again"))
    }
}
