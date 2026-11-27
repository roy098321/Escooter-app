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
}
