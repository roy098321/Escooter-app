import Foundation

// M3-03 · CALC_SPEC M25 (real range) and M37 (charge-time estimate). The shown numbers are honest (P-1): the 10% decision
// margin (T101, `SafetyMargin.forDecision`) is only in `decisionRangeKm`, which a decision (e.g. "will it reach?") uses.

/// One ride as the range needs it.
public struct RangeRide: Equatable, Sendable {
    public var startAt: Int64
    public var kind: String
    public var isSimulated: Bool
    public var distanceM: Double?
    /// Battery used (rested drop, or from energy once calibrated)
    public var usedPct: Double?
    /// V x I Wh of the ride (nil in phone mode)
    public var energyWhRaw: Double?
    /// Longest scooter gap in the ride, s (energy of a ride with a long gap is too low to use)
    public var gapScooterS: Double
    /// Battery % at the end of the ride (rested end, else the last live %), for "went low" (M25 below 20%)
    public var endPct: Double?

    public init(startAt: Int64, kind: String = "ride", isSimulated: Bool = false, distanceM: Double?, usedPct: Double?,
                energyWhRaw: Double? = nil, gapScooterS: Double = 0, endPct: Double? = nil) {
        self.startAt = startAt
        self.kind = kind
        self.isSimulated = isSimulated
        self.distanceM = distanceM
        self.usedPct = usedPct
        self.energyWhRaw = energyWhRaw
        self.gapScooterS = gapScooterS
        self.endPct = endPct
    }
}

public struct RealRange: Equatable, Sendable {
    public var currentPct: Double
    public var reservePct: Double
    /// My battery % per km (median of the last 10 rides)
    public var pctPerKm: Double
    public var basedOnRides: Int
    /// No ride has a used % yet: from the usual Wh per km and the calibration
    public var fromEnergy: Bool
    /// Below 20% (T81): shown with "~"
    public var lowBattery: Bool
    /// Honest range, km: (current - reserve) / %/km
    public var rangeKm: Double
    /// What a decision uses: the %/km with the 10% margin
    public var decisionRangeKm: Double

    public init(currentPct: Double, reservePct: Double, pctPerKm: Double, basedOnRides: Int, fromEnergy: Bool, lowBattery: Bool,
                rangeKm: Double, decisionRangeKm: Double) {
        self.currentPct = currentPct
        self.reservePct = reservePct
        self.pctPerKm = pctPerKm
        self.basedOnRides = basedOnRides
        self.fromEnergy = fromEnergy
        self.lowBattery = lowBattery
        self.rangeKm = rangeKm
        self.decisionRangeKm = decisionRangeKm
    }

    /// "27 km from 64% at your recent 2.3%/km · based on your last 10 rides"
    public var text: String {
        let km = (lowBattery ? "~" : "") + RealRangeCalc.kmText(rangeKm)
        let rate = String(format: "%.1f", pctPerKm)
        let basis = fromEnergy ? "from your Wh per km and the calibration"
            : "based on your last \(basedOnRides) ride\(basedOnRides == 1 ? "" : "s")"
        return "\(km) from \(Int(currentPct.rounded()))% at your recent \(rate)%/km · \(basis)"
    }

    /// A decision: does `km` fit with the safety margin?
    public func fits(km: Double) -> Bool { decisionRangeKm >= km }
}

public enum RealRangeCalc {
    /// Where the battery ran out (setting `t80.batteryRanOut`, JSON with a "pct" number), else 5% (T80)
    public static func reservePct(ranOutJson: String?) -> Double {
        guard let data = ranOutJson?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pct = (obj["pct"] as? NSNumber)?.doubleValue, pct >= 0, pct <= 100 else { return T.t80ReserveDefaultPct }
        return pct
    }

    public static func kmText(_ km: Double) -> String {
        km < 10 ? String(format: "%.1f km", km) : "\(Int(km.rounded())) km"
    }

    /// M25. `currentPct` = the current rested % (nil: unknown, so no range). No usable ride gives nil.
    public static func compute(currentPct: Double?, rides: [RangeRide], calibration: BatteryCalibration,
                               reservePct: Double = T.t80ReserveDefaultPct) -> RealRange? {
        guard let current = currentPct else { return nil }
        let real = rides.filter { !$0.isSimulated && $0.kind == "ride" && ($0.distanceM ?? 0) >= 1_000 }.sorted { $0.startAt > $1.startAt }
        let low = current < T.t81LowBatteryPct

        func rate(_ r: RangeRide) -> Double? {
            guard let u = r.usedPct, u > 0, let d = r.distanceM else { return nil }
            return u / (d / 1000)
        }
        var pool = real.filter { rate($0) != nil }
        // below 20%: the %/km of rides that went low, when there are any (it climbs as the battery empties)
        if low {
            let wentLow = pool.filter { ($0.endPct ?? 100) < T.t81LowBatteryPct }
            if !wentLow.isEmpty { pool = wentLow }
        }
        let used = Array(pool.prefix(T.t85RealRangeRides))
        var perKm: Double?
        var fromEnergy = false
        var n = used.count
        if let m = BatteryCalibrator.median(used.compactMap { rate($0) }) {
            perKm = m
        } else {
            var whPerKm: [Double] = []
            for r in real {
                guard let e = r.energyWhRaw, e > 0, r.gapScooterS <= T.t41CalibrationMaxGapS, let d = r.distanceM else { continue }
                whPerKm.append(e / (d / 1000))
                if whPerKm.count == T.t85RealRangeRides { break }
            }
            guard let m = BatteryCalibrator.median(whPerKm) else { return nil }
            perKm = calibration.pctPerKm(whPerKm: m)
            fromEnergy = true
            n = whPerKm.count
        }
        guard let p = perKm, p > 0 else { return nil }
        let avail = max(0, current - reservePct)
        return RealRange(currentPct: current, reservePct: reservePct, pctPerKm: p, basedOnRides: n, fromEnergy: fromEnergy,
                         lowBattery: low, rangeKm: avail / p, decisionRangeKm: avail / SafetyMargin.forDecision(p))
    }
}

/// M37 charge-time estimate: steady to 85%, the last 15% takes 1 hour (T46), charger 2.0 A.
public enum ChargeTime {
    public static func hoursToFull(fromPct pct: Double, packAh: Double, chargerA: Double = T.t46ChargerA) -> Double {
        let p = min(100, max(0, pct))
        let steady = max(0, T.t46SteadyToPct - p) / 100 * packAh / chargerA
        let hour = T.t46LastPartS / 3_600
        let final = p <= T.t46SteadyToPct ? hour : hour * (100 - p) / (100 - T.t46SteadyToPct)
        return steady + final
    }

    /// Rounded to 0.5 h (never 0 while not full)
    public static func rounded(_ hours: Double) -> Double {
        guard hours > 0 else { return 0 }
        return max(0.5, (hours * 2).rounded() / 2)
    }

    /// "~4.5 h" (full gives "Full")
    public static func text(hours: Double) -> String {
        let r = rounded(hours)
        if r == 0 { return "Full" }
        return r == r.rounded() ? "~\(Int(r)) h" : String(format: "~%.1f h", r)
    }

    /// Latest ride's "To full" tile: when it would be full if plugged in as the ride ended (epoch ms)
    public static func fullAt(endAtMs: Int64, endPct: Double, packAh: Double) -> Int64 {
        endAtMs + Int64((rounded(hoursToFull(fromPct: endPct, packAh: packAh)) * 3_600_000).rounded())
    }
}
