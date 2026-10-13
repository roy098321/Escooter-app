import XCTest
@testable import CorckieCore

/// F-01: lifetime numbers, pre-app km spread from the purchase date, and the price lock (past months never change).
final class OverallStatsTests: XCTestCase {
    let fuel = PriceHistory([PricePoint(validFrom: "2026-09-01", value: 8.25), PricePoint(validFrom: "2026-10-01", value: 8.27)])
    let elec = PriceHistory([PricePoint(validFrom: "2000-01-01", value: 0.64)])

    private func input(rides: [OverallRide] = [OverallRide(day: "2026-10-05", km: 19, usedPct: 40)], latestOdo: Double? = 711.1,
                       fuel: PriceHistory? = nil, elec: PriceHistory? = nil, today: String = "2026-10-13") -> OverallInput {
        OverallInput(purchaseDay: "2026-09-02", odometerAtPurchaseKm: 0, latestOdometerKm: latestOdo, odometerAtFirstRideKm: 692.1,
                     rides: rides, carLPer100km: 7, whPerPct: 8.0, fuel: fuel ?? self.fuel, electricity: elec ?? self.elec, todayDay: today)
    }

    func test_dayNumber_roundTripsWithDayKey() {
        XCTAssertEqual(OverallCalc.dayNumber("1970-01-01"), 0)
        let d = OverallCalc.dayNumber("2026-09-02")!
        XCTAssertEqual(RideListLogic.dayKey(d), "2026-09-02")
        XCTAssertEqual(OverallCalc.dayNumber("2026-10-05")! - d, 33)
        XCTAssertNil(OverallCalc.dayNumber("nope"))
    }

    func test_priceHistory_validFromAndFirstPointBefore() {
        XCTAssertEqual(fuel.value(on: "2026-09-30"), 8.25)
        XCTAssertEqual(fuel.value(on: "2026-10-01"), 8.27)
        XCTAssertEqual(fuel.value(on: "2026-08-15"), 8.25, "before the first point: the first one")
        XCTAssertNil(PriceHistory().value(on: "2026-10-01"))
    }

    func test_preAppKm_spreadEvenly_overThe34Days_thenSplitByMonth() {
        let s = OverallCalc.compute(input())
        XCTAssertEqual(s.kmBefore, 692.1, accuracy: 1e-9)
        XCTAssertEqual(s.kmWithApp, 19, accuracy: 1e-9)
        XCTAssertEqual(s.totalKm, 711.1, accuracy: 1e-9)
        let sep = s.months.first { $0.month == "2026-09" }!
        let oct = s.months.first { $0.month == "2026-10" }!
        // 2 Sep - 5 Oct inclusive = 34 days: 29 in September, 5 in October
        XCTAssertEqual(sep.preAppKm, 692.1 * 29 / 34, accuracy: 1e-6)
        XCTAssertEqual(oct.preAppKm, 692.1 * 5 / 34, accuracy: 1e-6)
        XCTAssertEqual(sep.fuelSavedIls, 692.1 * 29 / 34 * 0.07 * 8.25, accuracy: 1e-6)
        XCTAssertEqual(oct.fuelSavedIls, (692.1 * 5 / 34 + 19) * 0.07 * 8.27, accuracy: 1e-6)
    }

    func test_netSaved_isFuelMinusElectricity_andCo2UsesPetrolMinusGrid() {
        let s = OverallCalc.compute(input())
        XCTAssertEqual(s.netSavedIls, s.fuelSavedIls - s.electricityIls, accuracy: 1e-9)
        XCTAssertGreaterThan(s.netSavedIls, 0)
        XCTAssertEqual(s.carLitres, 711.1 * 0.07, accuracy: 1e-6)
        XCTAssertEqual(s.co2AvoidedKg, s.carLitres * 2.31 - s.lifetimeKwh * OverallCalc.gridCo2KgPerKwh, accuracy: 1e-9)
        XCTAssertGreaterThan(s.fullCharges, 0)
    }

    /// The owner's concern: a lower price from today on leaves every past month's money unchanged, and the lifetime total never goes down.
    func test_priceLock_loweringThePrice_leavesPastMonthsUnchanged() {
        let before = OverallCalc.compute(input())
        let lower = fuel.adding(PricePoint(validFrom: "2026-10-14", value: 6.00))      // from tomorrow on
        let after = OverallCalc.compute(input(fuel: lower))
        XCTAssertEqual(after.fuelSavedIls, before.fuelSavedIls, accuracy: 1e-9)
        XCTAssertEqual(after.months, before.months, "no past month changes")
        // a ride after the new price adds money at the new price: the total grows, more slowly, never shrinks
        let rides = [OverallRide(day: "2026-10-05", km: 19, usedPct: 40), OverallRide(day: "2026-10-15", km: 10, usedPct: 8)]
        let withRide = OverallCalc.compute(input(rides: rides, latestOdo: 721.1, fuel: lower))
        XCTAssertGreaterThan(withRide.netSavedIls, after.netSavedIls)
        // September's money from fuel is the same (the pre-app electricity follows the refined Wh per km, a km estimate, not a price)
        XCTAssertEqual(withRide.months.first { $0.month == "2026-09" }!.fuelSavedIls, before.months.first { $0.month == "2026-09" }!.fuelSavedIls, accuracy: 1e-9)
        let octAfter = withRide.months.first { $0.month == "2026-10" }!
        let octBefore = after.months.first { $0.month == "2026-10" }!
        XCTAssertEqual(octAfter.fuelSavedIls - octBefore.fuelSavedIls, 10 * 0.07 * 6.00, accuracy: 1e-9)
    }

    func test_priceLock_electricityRateRise_onlyAppliesFromItsDate() {
        let before = OverallCalc.compute(input())
        let dearer = elec.adding(PricePoint(validFrom: "2026-10-14", value: 1.50))
        let after = OverallCalc.compute(input(elec: dearer))
        XCTAssertEqual(after.electricityIls, before.electricityIls, accuracy: 1e-9)
        XCTAssertEqual(after.months, before.months)
    }

    func test_noFuelPrice_moneyStaysZero_kmStillCount() {
        let s = OverallCalc.compute(input(fuel: PriceHistory()))
        XCTAssertFalse(s.hasFuelPrice)
        XCTAssertEqual(s.fuelSavedIls, 0)
        XCTAssertEqual(s.totalKm, 711.1, accuracy: 1e-9)
    }

    func test_unverifiedSeptemberPlaceholder_isFlagged() {
        let placeholder = PriceHistory([PricePoint(validFrom: "2026-09-01", value: 8.27, unverified: true), PricePoint(validFrom: "2026-10-01", value: 8.27)])
        XCTAssertTrue(OverallCalc.compute(input(fuel: placeholder)).usesUnverifiedPrice)
        XCTAssertFalse(OverallCalc.compute(input()).usesUnverifiedPrice)
    }

    func test_noRidesYet_usesOdometerOnly() {
        var i = input(rides: [], latestOdo: 120)
        i.odometerAtFirstRideKm = nil
        let s = OverallCalc.compute(i)
        XCTAssertEqual(s.totalKm, 120, accuracy: 1e-9)
        XCTAssertEqual(s.kmBefore, 0)
    }

    func test_odometerAtPurchase_isSubtracted() {
        var i = input()
        i.odometerAtPurchaseKm = 100
        let s = OverallCalc.compute(i)
        XCTAssertEqual(s.kmBefore, 592.1, accuracy: 1e-9)
        XCTAssertEqual(s.totalKm, 611.1, accuracy: 1e-9)
    }
}
