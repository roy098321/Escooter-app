import Foundation

/// Hotfix .14 (B114, owner 27 Nov): ONE rule for the money a ride saved, used by the Stats periods (`StatsCalc.totals` follows the
/// same M35b rule) and the lifetime / last-30-days numbers, so a period can never show more saved than the lifetime.
/// A ride saves when it is a real ride (not a short hop) over 2 km: the same km by car at the fuel price of its day, minus what the
/// ride cost in electricity at that day's rate. Money saved belongs to the rider: every real ride counts, whichever scooter it was on.
public enum SavingsRule {
    public static let minKm = 2.0
    /// Owner 27 Nov (option B): saved per km over the last 30 days, so it follows today's prices instead of being anchored by
    /// lifetime km; under this many km in the window the lifetime number is shown instead (labelled so)
    public static let windowDays = 30
    public static let windowMinKm = 20.0

    /// One ride's net saving in ILS; 0 for a short hop or a ride of 2 km or less; nil without any fuel price
    public static func net(_ r: StatsRide, prices: StatsPrices) -> Double? {
        let km = r.distanceM / 1000
        guard r.kind == "ride", km > minKm else { return 0 }
        let dayKey = RideListLogic.dayKey(RideListLogic.localDay(startAt: r.startAt, utcOffsetMin: r.utcOffsetMin))
        guard let price = prices.fuelHistory?.value(on: dayKey)
                ?? StatsCalc.fuelPrice(forStart: r.startAt, offsetMin: r.utcOffsetMin, prices: prices) else { return nil }
        let rate = prices.electricityHistory?.value(on: dayKey) ?? prices.electricityIlsPerKwh
        return km * prices.fuelLPer100km / 100 * price - (r.usedPct ?? 0) * (prices.packWh / 100 / 1000) * rate
    }

    public struct Total: Equatable, Sendable {
        public var savedIls: Double
        /// km of the rides counted (real rides and short hops: "per km ridden")
        public var km: Double
        public var priced: Bool
    }

    public static func total(_ rides: [StatsRide], prices: StatsPrices) -> Total {
        var t = Total(savedIls: 0, km: 0, priced: false)
        for r in rides {
            t.km += max(0, r.distanceM / 1000)
            if let n = net(r, prices: prices) {
                t.savedIls += n
                if r.kind == "ride", r.distanceM / 1000 > minKm { t.priced = true }
            }
        }
        return t
    }

    /// The rides of the last `windowDays` days before `nowMs`
    public static func window(_ rides: [StatsRide], nowMs: Int64) -> [StatsRide] {
        let from = nowMs - Int64(windowDays) * 86_400_000
        return rides.filter { $0.startAt >= from && $0.startAt <= nowMs }
    }
}

/// Hotfix .14: what the Saved per km tile shows: the last 30 days, or the lifetime when the window has too few km
public struct SavedPerKmValue: Equatable, Sendable {
    public var perKm: Double
    public var savedIls: Double
    public var km: Double
    public var isWindow: Bool

    /// "last 30 days" / "lifetime"
    public var label: String { isWindow ? "last \(SavingsRule.windowDays) days" : "lifetime" }

    public static func make(window: SavingsRule.Total, lifetimeSavedIls: Double, lifetimeKm: Double) -> SavedPerKmValue? {
        if window.km >= SavingsRule.windowMinKm, window.priced {
            let saved = max(0, InfoFormula.round(window.savedIls))
            return SavedPerKmValue(perKm: InfoFormula.shownPerKm(saved: saved, km: window.km, kmDecimals: InfoFormula.kmDecimals(window.km)),
                                   savedIls: saved, km: window.km, isWindow: true)
        }
        guard lifetimeKm > 0 else { return nil }
        let saved = max(0, InfoFormula.round(lifetimeSavedIls))
        return SavedPerKmValue(perKm: InfoFormula.shownPerKm(saved: saved, km: lifetimeKm, kmDecimals: InfoFormula.kmDecimals(lifetimeKm)),
                               savedIls: saved, km: lifetimeKm, isWindow: false)
    }
}
