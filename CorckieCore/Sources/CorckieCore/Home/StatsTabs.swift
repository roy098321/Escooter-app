import Foundation

/// Hotfix .14 (N12-6, owner 26–27 Nov; mock reports/mocks/stats_tabs.png): the numbers behind Stats' three tabs, Rides · Money ·
/// Energy. Pure, so it is tested on Linux. No time-of-day numbers (when the rider rides is never learned).
public enum StatsTab: String, CaseIterable, Sendable {
    case rides, money, energy
    public var title: String {
        switch self {
        case .rides: return "Rides"
        case .money: return "Money"
        case .energy: return "Energy"
        }
    }
}

/// Rides tab, "Per ride": real rides only (short hops are not rides)
public struct PeriodRideStats: Equatable, Sendable {
    public var avgKm: Double
    public var avgSeconds: Double
    /// distance ÷ riding time of the period's rides
    public var avgKmh: Double?
    public var longestKm: Double
    public var topKmh: Double?

    public static func make(_ rides: [StatsRide]) -> PeriodRideStats? {
        let real = rides.filter { $0.kind == "ride" && $0.distanceM > 0 }
        guard !real.isEmpty else { return nil }
        let km = real.reduce(0.0) { $0 + $1.distanceM / 1000 }
        let s = real.reduce(0.0) { $0 + $1.totalS }
        let n = Double(real.count)
        return PeriodRideStats(avgKm: km / n, avgSeconds: s / n, avgKmh: s > 0 ? km / (s / 3600) : nil,
                               longestKm: real.map { $0.distanceM / 1000 }.max() ?? 0,
                               topKmh: real.compactMap(\.topSpeedMps).max().map { $0 * 3.6 })
    }
}

/// Energy tab: the period's battery use in real-world terms
public struct PeriodEnergy: Equatable, Sendable {
    public var whPerKm: Double
    public var kmPerPct: Double
    public var fullCharges: Double
    public var kWh: Double

    public static func make(_ t: StatsTotals, packWh: Double) -> PeriodEnergy? {
        let km = t.km + t.shortHopKm
        guard km > 0, t.charges > 0, packWh > 0 else { return nil }
        let wh = t.charges * packWh
        return PeriodEnergy(whPerKm: wh / km, kmPerPct: km / (t.charges * 100), fullCharges: t.charges, kWh: wh / 1000)
    }

    /// Range from full at this period's use
    public var rangeKm: Double { kmPerPct * 100 }
}

/// Energy tab: Wh per km of each of the last rides (real rides over 2 km with a battery reading), oldest first
public struct RideEnergyPoint: Equatable, Sendable {
    public var startAt: Int64
    public var whPerKm: Double

    public static let count = 10

    public static func last(_ rides: [StatsRide], packWh: Double, count: Int = count) -> [RideEnergyPoint] {
        let usable = rides.filter { $0.kind == "ride" && $0.distanceM > SavingsRule.minKm * 1000 && ($0.usedPct ?? 0) > 0 }
            .sorted { $0.startAt < $1.startAt }
        return usable.suffix(count).map { RideEnergyPoint(startAt: $0.startAt, whPerKm: ($0.usedPct ?? 0) * packWh / 100 / ($0.distanceM / 1000)) }
    }
}

/// Money tab: the running total saved by month ("yyyy-MM", cumulative ILS), from every real ride by `SavingsRule`
public struct SavedByMonth: Equatable, Sendable {
    public var month: String
    public var cumulativeIls: Double

    public static func make(_ rides: [StatsRide], prices: StatsPrices, startIls: Double = 0) -> [SavedByMonth] {
        var byMonth: [String: Double] = [:]
        for r in rides {
            guard let n = SavingsRule.net(r, prices: prices) else { continue }
            let day = RideListLogic.dayKey(RideListLogic.localDay(startAt: r.startAt, utcOffsetMin: r.utcOffsetMin))
            byMonth[String(day.prefix(7)), default: 0] += n
        }
        var total = startIls
        return byMonth.keys.sorted().map { m in
            total += byMonth[m] ?? 0
            return SavedByMonth(month: m, cumulativeIls: total)
        }
    }
}

/// Money tab: "Scooter paid off", only once the rider has entered what the scooter cost
public struct PaidOff: Equatable, Sendable {
    public var fraction: Double
    public var savedIls: Double
    public var priceIls: Double

    public static func make(savedIls: Double, priceIls: Double?) -> PaidOff? {
        guard let p = priceIls, p > 0 else { return nil }
        return PaidOff(fraction: min(1, max(0, savedIls) / p), savedIls: max(0, savedIls), priceIls: p)
    }

    /// "34%"
    public var pctText: String { "\(Int((fraction * 100).rounded(.down)))%" }
    /// "₪ 2,140 of ₪ 6,300"
    public var line: String { "\(StatsCalc.money(savedIls)) of \(StatsCalc.money(priceIls))" }
}
