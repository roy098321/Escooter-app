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
        let data = (try? q.overallRows()) ?? ([], nil, nil)
        let rides = data.rides.map { OverallRide(day: localDay($0.startAt, offsetMin: $0.offsetMin), km: $0.km, usedPct: $0.usedPct) }
        return OverallInput(purchaseDay: OverallSettings.purchaseDay(db), odometerAtPurchaseKm: OverallSettings.odometerAtPurchase(db),
                            latestOdometerKm: data.latestOdoKm, odometerAtFirstRideKm: data.firstOdoKm, rides: rides,
                            carLPer100km: q.number(StatsQueries.fuelUseKey) ?? StatsPrices.defaultFuelLPer100km,
                            whPerPct: CalibrationUpdater.current(db).whPerPct, fuel: fuelHistory(db), electricity: electricityHistory(db),
                            todayDay: localDay(nowMs, offsetMin: utcOffsetMin))
    }

    static func load(_ db: AppDatabase, nowMs: Int64 = FactorUpdater.nowMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> OverallStats {
        OverallCalc.compute(input(db, nowMs: nowMs, utcOffsetMin: utcOffsetMin))
    }

    /// Texts of the Overall section (the view draws them; the ui-shot preview uses the same)
    static func tiles(_ s: OverallStats) -> [(label: String, value: String, note: String?)] {
        var out: [(label: String, value: String, note: String?)] = [
            ("Total distance", OverallCalc.km(s.totalKm), "scooter odometer"),
            ("With CorckieApp", OverallCalc.km(s.kmWithApp), "logged rides"),
            ("Before CorckieApp", OverallCalc.km(s.kmBefore), OverallCalc.beforeLabel),
            ("A car would have burnt", OverallCalc.litres(s.carLitres), "of petrol"),
        ]
        if s.hasFuelPrice {
            out.append(("Fuel money saved", StatsCalc.money(max(0, s.fuelSavedIls)), "each month at that month's price"))
            out.append(("Electricity spent", StatsCalc.money(s.electricityIls), "at the rate valid at the time"))
            out.append(("Net saved", StatsCalc.money(s.netSavedIls), s.usesUnverifiedPrice ? "uses an unverified fuel price, please check" : "fuel saved minus electricity"))
        }
        out.append(("CO\u{2082} avoided", OverallCalc.co2(s.co2AvoidedKg), "estimate: petrol minus grid electricity"))
        out.append(("Full charges", StatsCalc.charges(s.fullCharges), "estimate"))
        return out
    }
}
