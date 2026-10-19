import CorckieCore
import Foundation

// F-01: builds the Overall numbers from the stored rides, the price history and the purchase settings (Core `OverallCalc`, unit tested).
// Compiled into AppTests (database only, no UI types).

enum OverallSettings {
    static let purchaseDayKey = "overall.purchaseDay"
    static let purchaseOdoKey = "overall.purchaseOdoKm"
    /// Owner, 13 Oct: bought on 2 Sep 2026
    static let defaultPurchaseDay = "2026-09-02"

    static func purchaseDay(_ db: AppDatabase?) -> String { SettingsValue.text(db, purchaseDayKey) ?? defaultPurchaseDay }
    static func odometerAtPurchase(_ db: AppDatabase?) -> Double { SettingsValue.number(db, purchaseOdoKey) ?? 0 }
}

enum OverallLoader {
    static func history(_ rows: [PriceRow]) -> PriceHistory {
        PriceHistory(rows.map { PricePoint(validFrom: $0.validFrom, value: $0.value, unverified: $0.unverified) })
    }

    static func fuelHistory(_ db: AppDatabase) -> PriceHistory { history((try? PriceHistoryQueries(db).rows(kind: PriceHistoryQueries.fuel)) ?? []) }

    static func electricityHistory(_ db: AppDatabase) -> PriceHistory {
        let h = history((try? PriceHistoryQueries(db).rows(kind: PriceHistoryQueries.electricity)) ?? [])
        if !h.isEmpty { return h }
        // no history yet: the single rate that was set (or the default) has always applied
        let rate = StatsQueries(db).number(StatsQueries.electricityKey) ?? StatsPrices.defaultElectricityIlsPerKwh
        return PriceHistory([PricePoint(validFrom: "2000-01-01", value: rate)])
    }

    static func localDay(_ ms: Int64, offsetMin: Int) -> String { RideListLogic.dayKey(RideListLogic.localDay(startAt: ms, utcOffsetMin: offsetMin)) }

    static func input(_ db: AppDatabase, nowMs: Int64, utcOffsetMin: Int) -> OverallInput {
        let q = StatsQueries(db)
        let data = try? q.overallRows()
        let rides = (data?.rides ?? []).map { OverallRide(day: localDay($0.startAt, offsetMin: $0.offsetMin), km: $0.km, usedPct: $0.usedPct) }
        return OverallInput(purchaseDay: OverallSettings.purchaseDay(db), odometerAtPurchaseKm: OverallSettings.odometerAtPurchase(db),
                            latestOdometerKm: data?.latestOdoKm, odometerAtFirstRideKm: data?.firstOdoKm, rides: rides,
                            carLPer100km: q.number(StatsQueries.fuelUseKey) ?? StatsPrices.defaultFuelLPer100km,
                            whPerPct: CalibrationUpdater.current(db).whPerPct, fuel: fuelHistory(db), electricity: electricityHistory(db),
                            todayDay: localDay(nowMs, offsetMin: utcOffsetMin))
    }

    static func load(_ db: AppDatabase, nowMs: Int64 = FactorUpdater.nowMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> OverallStats {
        OverallCalc.compute(input(db, nowMs: nowMs, utcOffsetMin: utcOffsetMin))
    }

    /// ST5: the four headline tiles of the Overall section (km on the odometer, money saved, litres of fuel not burnt, CO2 not emitted)
    static func tiles(_ s: OverallStats) -> [(label: String, value: String)] {
        var out: [(label: String, value: String)] = [("Total distance", OverallCalc.km(s.totalKm))]
        if s.hasFuelPrice { out.append(("Saved", StatsCalc.money(max(0, s.netSavedIls)))) }
        out.append(("Fuel not burnt", OverallCalc.litres(s.carLitres)))
        out.append(("CO\u{2082} avoided", String(format: "%.0f kg", max(0, s.co2AvoidedKg))))
        return out
    }

    /// F-20: the ⓘ of the "saved per km" tile
    static func perKmInfo(_ s: OverallStats) -> String {
        let l100 = String(format: "%.0f", s.carLPer100km)
        var text = "Every kilometre you ride instead of driving saves this much: the fuel a car would burn at your \(l100) L per 100 km, at each month's fuel price, minus the electricity of the scooter."
        if s.totalKm > 0 { text += " Lifetime: \(StatsCalc.money(max(0, s.netSavedIls))) over \(OverallCalc.km(s.totalKm))." }
        return text
    }

    /// Everything else, for the ⓘ next to the Overall header
    static func details(_ s: OverallStats) -> String {
        var lines = [
            "Total distance is the scooter's odometer.",
            "With CorckieApp: \(OverallCalc.km(s.kmWithApp)), logged rides.",
            "Before the app: \(OverallCalc.km(s.kmBefore)), an estimate from the purchase date.",
            "Full charges used: " + String(format: "%.1f", s.fullCharges) + ".",
        ]
        if s.hasFuelPrice {
            lines.append("Fuel money saved: \(StatsCalc.money(max(0, s.fuelSavedIls))). Electricity spent: \(StatsCalc.money(s.electricityIls)). Saved is the difference.")
            lines.append("Money is counted month by month at the price valid then; a later price never changes past months.")
        }
        lines.append("Fuel not burnt is what a car would have burnt for the same distance. CO\u{2082} avoided is an estimate: petrol minus grid electricity.")
        if s.usesUnverifiedPrice { lines.append("The September fuel price is unverified. Please check it in Settings, Costs, Price history.") }
        return lines.joined(separator: "\n\n")
    }
}
