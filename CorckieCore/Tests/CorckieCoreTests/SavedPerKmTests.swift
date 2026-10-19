import XCTest
@testable import CorckieCore

/// F-20: the "0.77 ₪ / km saved" tile = lifetime net saved ÷ lifetime km (809.65 ₪ ÷ 1054 km in the owner's screenshot).
final class SavedPerKmTests: XCTestCase {
    func test_ownersNumbers_giveAbout077() throws {
        var s = OverallStats()
        s.hasFuelPrice = true
        s.totalKm = 1_054
        s.fuelSavedIls = 900
        s.electricityIls = 90.35
        XCTAssertEqual(s.netSavedIls, 809.65, accuracy: 1e-9)
        let v = try XCTUnwrap(OverallCalc.savedPerKm(s))
        XCTAssertEqual(v, 809.65 / 1_054, accuracy: 1e-9)
        XCTAssertEqual(OverallCalc.perKmText(v), "0.77 \u{20AA}")
    }

    func test_noFuelPrice_orNoKm_orNegative() {
        var s = OverallStats()
        s.totalKm = 100
        s.fuelSavedIls = 50
        XCTAssertNil(OverallCalc.savedPerKm(s), "no fuel price: no number")
        s.hasFuelPrice = true
        s.totalKm = 0
        XCTAssertNil(OverallCalc.savedPerKm(s), "no km: no number")
        s.totalKm = 100
        s.fuelSavedIls = 10
        s.electricityIls = 30
        XCTAssertEqual(OverallCalc.savedPerKm(s), 0, "never negative")
    }

    func test_fromARealComputation_isNetSavedOverOdometerKm() throws {
        let fuel = PriceHistory([PricePoint(validFrom: "2026-09-01", value: 8.25)])
        let elec = PriceHistory([PricePoint(validFrom: "2000-01-01", value: 0.64)])
        let rides = [OverallRide(day: "2026-10-05", km: 19, usedPct: 48), OverallRide(day: "2026-10-08", km: 11, usedPct: 22)]
        let stats = OverallCalc.compute(OverallInput(purchaseDay: "2026-09-02", latestOdometerKm: 722.1, odometerAtFirstRideKm: 692.1, rides: rides,
                                                      whPerPct: 8.1, fuel: fuel, electricity: elec, todayDay: "2026-10-13"))
        let v = try XCTUnwrap(OverallCalc.savedPerKm(stats))
        XCTAssertEqual(v, stats.netSavedIls / stats.totalKm, accuracy: 1e-9)
        XCTAssertEqual(stats.totalKm, 722.1, accuracy: 1e-9)
        XCTAssertEqual(stats.carLPer100km, StatsPrices.defaultFuelLPer100km)
        // 722 km at 7 L per 100 km and about 8.25 per litre is about 0.58 per km before the electricity
        XCTAssertGreaterThan(v, 0.4)
        XCTAssertLessThan(v, 0.6)
    }
}
