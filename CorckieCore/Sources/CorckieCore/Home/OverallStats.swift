import Foundation

// F-01 Overall stats (owner, 13 Oct): lifetime numbers from the scooter's odometer plus outside facts, pure.
// Money is computed day by day at the price that was valid on that day, so a later price never rewrites the past:
// a new price only applies from its "valid from" date on. Pre-app km (before the first logged ride) are an estimate
// spread evenly over the days since the purchase date.

/// A price and the day it is valid from ("yyyy-MM-dd")
public struct PricePoint: Equatable, Sendable {
    public var validFrom: String
    public var value: Double
    /// "unverified - please check" placeholder rows
    public var unverified: Bool

    public init(validFrom: String, value: Double, unverified: Bool = false) {
        self.validFrom = validFrom
        self.value = value
        self.unverified = unverified
    }
}

/// Fuel price (ILS per litre) or electricity rate (ILS per kWh) over time.
public struct PriceHistory: Equatable, Sendable {
    public private(set) var points: [PricePoint]

    public init(_ points: [PricePoint] = []) {
        self.points = points.sorted { $0.validFrom < $1.validFrom }
    }

    public var isEmpty: Bool { points.isEmpty }

    /// The price valid on a day: the newest point whose date is not after the day; a day before the first point uses the first.
    public func value(on day: String) -> Double? {
        guard let first = points.first else { return nil }
        var best = first
        for p in points where p.validFrom <= day { best = p }
        return best.value
    }

    /// The same history with a new point (a point with the same date is replaced)
    public func adding(_ p: PricePoint) -> PriceHistory {
        PriceHistory(points.filter { $0.validFrom != p.validFrom } + [p])
    }
}

/// One logged ride as the overall numbers need it
public struct OverallRide: Equatable, Sendable {
    /// local day, "yyyy-MM-dd"
    public var day: String
    public var km: Double
    /// battery used, % (nil = unknown)
    public var usedPct: Double?

    public init(day: String, km: Double, usedPct: Double? = nil) {
        self.day = day
        self.km = km
        self.usedPct = usedPct
    }
}

public struct OverallInput: Equatable, Sendable {
    public var purchaseDay: String
    public var odometerAtPurchaseKm: Double
    /// Latest odometer reading (nil = none yet)
    public var latestOdometerKm: Double?
    /// Odometer at the start of the first logged ride (nil = none yet)
    public var odometerAtFirstRideKm: Double?
    public var rides: [OverallRide]
    public var carLPer100km: Double
    /// V x I Wh per 1 % of the battery (calibration), usable Wh = 100 x this
    public var whPerPct: Double
    public var fuel: PriceHistory
    public var electricity: PriceHistory
    public var todayDay: String

    public init(purchaseDay: String, odometerAtPurchaseKm: Double = 0, latestOdometerKm: Double?, odometerAtFirstRideKm: Double?,
                rides: [OverallRide], carLPer100km: Double = StatsPrices.defaultFuelLPer100km, whPerPct: Double,
                fuel: PriceHistory, electricity: PriceHistory, todayDay: String) {
        self.purchaseDay = purchaseDay
        self.odometerAtPurchaseKm = odometerAtPurchaseKm
        self.latestOdometerKm = latestOdometerKm
        self.odometerAtFirstRideKm = odometerAtFirstRideKm
        self.rides = rides
        self.carLPer100km = carLPer100km
        self.whPerPct = whPerPct
        self.fuel = fuel
        self.electricity = electricity
        self.todayDay = todayDay
    }
}

public struct OverallMonth: Equatable, Sendable {
    /// "yyyy-MM"
    public var month: String
    public var km: Double
    public var preAppKm: Double
    public var fuelSavedIls: Double
    public var electricityIls: Double
    public var netIls: Double { fuelSavedIls - electricityIls }
}

public struct OverallStats: Equatable, Sendable {
    public var totalKm = 0.0
    public var kmWithApp = 0.0
    public var kmBefore = 0.0
    public var carLitres = 0.0
    public var fuelSavedIls = 0.0
    public var electricityIls = 0.0
    public var netSavedIls: Double { fuelSavedIls - electricityIls }
    public var co2AvoidedKg = 0.0
    public var fullCharges = 0.0
    public var lifetimeKwh = 0.0
    /// Wh per km the electricity numbers used
    public var whPerKm = 0.0
    public var months: [OverallMonth] = []
    /// No fuel price at all: the money lines stay empty
    public var hasFuelPrice = false
    /// An unverified placeholder price is in use
    public var usesUnverifiedPrice = false

    public init() {}
}

public enum OverallCalc {
    /// Petrol: 2.31 kg CO2 per litre (owner, F-01).
    public static let co2KgPerLitrePetrol = 2.31
    /// Israeli grid average, kg CO2 per kWh. An estimate (about 0.45 in recent years); the one number to change when an official figure is chosen.
    public static let gridCo2KgPerKwh = 0.45
    /// Electricity rate used when none is set (ILS per kWh)
    public static let defaultElectricityIlsPerKwh = StatsPrices.defaultElectricityIlsPerKwh
    /// Wh per km when no logged ride has a battery figure yet (used only for the estimate)
    public static let fallbackWhPerKm = 20.0
    /// The label under pre-app numbers
    public static let beforeLabel = "before CorckieApp \u{00B7} estimated from the purchase date"

    // MARK: days

    /// Day number of a "yyyy-MM-dd" (days since 1970-01-01), nil when malformed
    public static func dayNumber(_ key: String) -> Int? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        let y = p[1] <= 2 ? p[0] - 1 : p[0]
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (p[1] + 9) % 12
        let doy = (153 * mp + 2) / 5 + p[2] - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func month(of day: String) -> String { String(day.prefix(7)) }

    // MARK: calc

    public static func compute(_ input: OverallInput) -> OverallStats {
        var out = OverallStats()
        let logged = input.rides.reduce(0.0) { $0 + max(0, $1.km) }
        out.kmWithApp = logged
        let rideDays = input.rides.compactMap { dayNumber($0.day) }
        let firstRideDay = rideDays.min()
        let purchase = dayNumber(input.purchaseDay)

        // km before the app: odometer at the first ride minus the odometer at purchase
        if let odoFirst = input.odometerAtFirstRideKm {
            out.kmBefore = max(0, odoFirst - input.odometerAtPurchaseKm)
        }
        out.totalKm = input.latestOdometerKm.map { max(0, $0 - input.odometerAtPurchaseKm) } ?? (out.kmBefore + logged)

        // Wh per km from the logged rides that know their battery use
        let known = input.rides.filter { $0.usedPct != nil && $0.km > 0 }
        let knownKm = known.reduce(0.0) { $0 + $1.km }
        let knownWh = known.reduce(0.0) { $0 + ($1.usedPct ?? 0) * input.whPerPct }
        out.whPerKm = knownKm > 0 ? knownWh / knownKm : fallbackWhPerKm
        let carL = input.carLPer100km / 100

        var byMonth: [String: OverallMonth] = [:]
        func add(day: String, km: Double, wh: Double, pre: Bool) {
            let m = month(of: day)
            var line = byMonth[m] ?? OverallMonth(month: m, km: 0, preAppKm: 0, fuelSavedIls: 0, electricityIls: 0)
            line.km += km
            if pre { line.preAppKm += km }
            out.carLitres += km * carL
            if let price = input.fuel.value(on: day) {
                line.fuelSavedIls += km * carL * price
                out.hasFuelPrice = true
                if input.fuel.points.contains(where: { $0.unverified && $0.validFrom <= day }) { out.usesUnverifiedPrice = true }
            }
            let rate = input.electricity.value(on: day) ?? defaultElectricityIlsPerKwh
            line.electricityIls += wh / 1000 * rate
            out.lifetimeKwh += wh / 1000
            byMonth[m] = line
        }

        // logged rides, at their own day's prices
        for r in input.rides where r.km > 0 {
            let wh = r.usedPct.map { $0 * input.whPerPct } ?? r.km * out.whPerKm
            add(day: r.day, km: r.km, wh: wh, pre: false)
        }
        // before the app: spread evenly per day from the purchase day to the first logged ride's day (both included)
        if out.kmBefore > 0, let start = purchase {
            let end = max(firstRideDay ?? start, start)
            let n = end - start + 1
            let perDay = out.kmBefore / Double(n)
            for d in start...end {
                add(day: RideListLogic.dayKey(d), km: perDay, wh: perDay * out.whPerKm, pre: true)
            }
        }

        out.months = byMonth.values.sorted { $0.month < $1.month }
        out.fuelSavedIls = out.months.reduce(0) { $0 + $1.fuelSavedIls }
        out.electricityIls = out.months.reduce(0) { $0 + $1.electricityIls }
        out.co2AvoidedKg = out.carLitres * co2KgPerLitrePetrol - out.lifetimeKwh * gridCo2KgPerKwh
        let usableWh = input.whPerPct * 100
        out.fullCharges = usableWh > 0 ? out.lifetimeKwh * 1000 / usableWh : 0
        return out
    }

    // MARK: text

    public static func km(_ v: Double) -> String { String(format: v >= 100 ? "%.0f km" : "%.1f km", v) }
    public static func co2(_ kg: Double) -> String { String(format: "~%.0f kg", max(0, kg)) }
    public static func litres(_ l: Double) -> String { String(format: "%.0f L", l) }
}
