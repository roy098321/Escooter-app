import Foundation

// M3-01 · CALC_SPEC M8 S1 (amended P2 S12): the battery is calibrated from rides, never from a watched charge.
// For each qualifying ride: raw energy (Σ V × I × Δt, M8) ÷ the drop in rested %. That is "V × I Wh per 1%"; the
// spec's factor k = that ÷ (pack Wh ÷ 100). The median over the newest 10 qualifying rides is the measured value;
// before 5 rides it is blended with a prior from the 16 Ah pack, so the value can be used from day one and only
// gets "calibrated" after 5 rides (T41). The 10% decision margin (T101) is never in here: these are honest numbers.

/// One stored ride, as the calibration needs it (the `ride` row + its longest scooter gap + its last live %).
public struct CalibrationRide: Equatable, Sendable {
    public var id: String
    /// epoch ms
    public var startAt: Int64
    public var endAt: Int64?
    /// ride / shortHop / discarded
    public var kind: String
    public var isSimulated: Bool
    /// M8 Σ V × I × Δt, Wh (scooter gaps carry none)
    public var energyWhRaw: Double?
    public var startRestPct: Double?
    public var endRestPct: Double?
    /// The last battery % read during the ride (under load it reads low: sag)
    public var lastLivePct: Double?
    /// Sag-aware end for a ride without a rested end (scooter switched off first): the next connection's start rested %,
    /// set by `BatteryCalibrator.linkNextStarts` (M3-02 replaces the rule with M30's charge detection)
    public var nextStartRestPct: Double?
    /// The longest scooter gap (phone mode, no energy) in the ride, s
    public var longestGapS: Double
    public var distanceM: Double?

    public init(id: String, startAt: Int64, endAt: Int64? = nil, kind: String = "ride", isSimulated: Bool = false,
                energyWhRaw: Double?, startRestPct: Double?, endRestPct: Double?, lastLivePct: Double? = nil,
                nextStartRestPct: Double? = nil, longestGapS: Double = 0, distanceM: Double? = nil) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.kind = kind
        self.isSimulated = isSimulated
        self.energyWhRaw = energyWhRaw
        self.startRestPct = startRestPct
        self.endRestPct = endRestPct
        self.lastLivePct = lastLivePct
        self.nextStartRestPct = nextStartRestPct
        self.longestGapS = longestGapS
        self.distanceM = distanceM
    }
}

/// Why a ride was left out of the calibration (shown in the check, never to the rider).
public enum CalibrationReject: String, Equatable, Sendable, CaseIterable {
    case simulated, notARide, noEnergy, noRestedStart, noRestedEnd, chargedBetween, smallDrop, gap, implausible, outlier
}

public enum CalibrationVerdict: Equatable, Sendable {
    /// Used: V × I Wh per 1%, the rested drop, and whether the end came from the next connection (sag-aware)
    case used(whPerPct: Double, dropPct: Double, endFromNextStart: Bool)
    case rejected(CalibrationReject)

    public var isUsed: Bool { if case .used = self { return true } else { return false } }
}

/// The calibration as everything else reads it (M3-02 charge log / health, M3-03 range / charge time, M2 Today via the rides).
public struct BatteryCalibration: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// No qualifying ride yet: the prior only
        case prior
        /// 1–4 qualifying rides: blended with the prior; rides keep the rested %
        case learning
        /// ≥ 5 qualifying rides (T41): rides' used % comes from energy
        case calibrated
    }

    public var packAh: Double
    /// V × I Wh per 1% of the battery (what the app uses)
    public var whPerPct: Double
    /// Median of the qualifying rides alone (nil before the first one)
    public var measuredWhPerPct: Double?
    public var ridesUsed: Int
    public var status: Status
    /// M8 confirmation: 3 rides in a row more than 5 points away from their rested drop → "Check battery calibration"
    public var checkSuggested: Bool

    public init(packAh: Double, whPerPct: Double, measuredWhPerPct: Double?, ridesUsed: Int, status: Status, checkSuggested: Bool = false) {
        self.packAh = packAh
        self.whPerPct = whPerPct
        self.measuredWhPerPct = measuredWhPerPct
        self.ridesUsed = ridesUsed
        self.status = status
        self.checkSuggested = checkSuggested
    }

    /// The starting point: 16 Ah × 48 V ÷ 100 × 1.06 ≈ 8.1 Wh per 1% (T41 prior, T42)
    public static func prior(packAh: Double = T.t42DefaultPackAh) -> BatteryCalibration {
        BatteryCalibration(packAh: packAh, whPerPct: priorWhPerPct(packAh: packAh), measuredWhPerPct: nil, ridesUsed: 0, status: .prior)
    }

    public static func priorWhPerPct(packAh: Double) -> Double { packAh * T.t42PackVoltage / 100 * T.t41PriorRawFactor }

    /// T42: label pack energy, Wh
    public var packWh: Double { packAh * T.t42PackVoltage }
    /// M8 factor k (stored in `calibration.factor`): V × I Wh per 1% ÷ (pack Wh ÷ 100)
    public var factor: Double { whPerPct / (packWh / 100) }
    /// V × I Wh from 100% to 0%
    public var usableWh: Double { whPerPct * 100 }
    /// 0…1, grows by 0.2 a qualifying ride (full at 5, T41)
    public var confidence: Double { min(1, Double(ridesUsed) / Double(T.t41CalibrationRides)) }
    public var isCalibrated: Bool { status == .calibrated }

    /// M8 main: used % from raw energy
    public func usedPct(energyWhRaw: Double) -> Double { max(0, energyWhRaw) / whPerPct }
    /// M8 `energyWhCal = E_raw ÷ k` (Wh of the label pack)
    public func energyWhCal(energyWhRaw: Double) -> Double { max(0, energyWhRaw) / factor }
    /// % for an amount of V × I Wh (charge log, range)
    public func pct(forWh wh: Double) -> Double { wh / whPerPct }
    /// V × I Wh for a battery % (charge log: Wh charged; range)
    public func wh(forPct pct: Double) -> Double { pct * whPerPct }
    /// Battery % per km from Wh per km (phone-mode estimate, range before %/km is known)
    public func pctPerKm(whPerKm: Double) -> Double { whPerKm / whPerPct }

    /// "8.3 Wh per 1% · 3 of 5 rides" (developer text; the battery page words come with M3-04)
    public var summaryText: String {
        let value = String(format: "%.2f Wh per 1%% (~%ld Wh usable)", whPerPct, Int(usableWh.rounded()))
        switch status {
        case .prior: return value + " · from the \(Int(packAh.rounded())) Ah pack, no ride yet"
        case .learning: return value + " · learning, \(ridesUsed) of \(T.t41CalibrationRides) rides"
        case .calibrated: return value + " · calibrated on \(ridesUsed) rides" + (checkSuggested ? " · check battery calibration" : "")
        }
    }
}

public enum BatteryCalibrator {
    /// One ride on its own (everything except the outlier test, which needs the others).
    public static func evaluate(_ r: CalibrationRide, packAh: Double = T.t42DefaultPackAh) -> CalibrationVerdict {
        if r.isSimulated { return .rejected(.simulated) }
        if r.kind != "ride" { return .rejected(.notARide) }
        guard let e = r.energyWhRaw, e > 0 else { return .rejected(.noEnergy) }
        if r.longestGapS > T.t41CalibrationMaxGapS { return .rejected(.gap) }
        guard let start = r.startRestPct else { return .rejected(.noRestedStart) }
        var end = r.endRestPct
        var fromNext = false
        if end == nil, let next = r.nextStartRestPct {
            // sag-aware: the live % read low under load and recovers at rest; a bigger rise is a charge
            if let live = r.lastLivePct, next > live + T.t41SagRecoveryPct { return .rejected(.chargedBetween) }
            if r.lastLivePct == nil { return .rejected(.noRestedEnd) }
            end = next
            fromNext = true
        }
        guard let endPct = end else { return .rejected(.noRestedEnd) }
        let drop = start - endPct
        if drop < T.t41CalibrationDropPct { return .rejected(.smallDrop) }
        let value = e / drop
        let prior = BatteryCalibration.priorWhPerPct(packAh: packAh)
        if value < prior * T.t41PlausibleLow || value > prior * T.t41PlausibleHigh { return .rejected(.implausible) }
        return .used(whPerPct: value, dropPct: drop, endFromNextStart: fromNext)
    }

    /// Sets `nextStartRestPct` on rides without a rested end, from the next ride (same simulated flag) that starts within
    /// 24 h (T41 sag rule). Rides in any order; returned newest first.
    public static func linkNextStarts(_ rides: [CalibrationRide]) -> [CalibrationRide] {
        var sorted = rides.sorted { $0.startAt < $1.startAt }
        for i in sorted.indices where sorted[i].endRestPct == nil && sorted[i].nextStartRestPct == nil {
            guard let next = sorted[(i + 1)...].first(where: { $0.isSimulated == sorted[i].isSimulated && $0.kind != "discarded" }),
                  let nextStart = next.startRestPct else { continue }
            let endMs = sorted[i].endAt ?? sorted[i].startAt
            if Double(next.startAt - endMs) / 1000 <= T.t41NextStartMaxS { sorted[i].nextStartRestPct = nextStart }
        }
        return sorted.reversed()
    }

    /// The calibration from all stored rides (any order). Verdicts are keyed by ride id.
    public static func calibrate(_ rides: [CalibrationRide], packAh: Double = T.t42DefaultPackAh)
        -> (calibration: BatteryCalibration, verdicts: [String: CalibrationVerdict]) {
        let newestFirst = rides.sorted { $0.startAt > $1.startAt }
        var verdicts: [String: CalibrationVerdict] = [:]
        var candidates: [(id: String, value: Double)] = []
        for r in newestFirst {
            let v = evaluate(r, packAh: packAh)
            verdicts[r.id] = v
            if case let .used(value, _, _) = v { candidates.append((r.id, value)) }
        }

        // outliers: further than 25% from the median of the other candidates (needs 3)
        var kept: [(id: String, value: Double)] = []
        if candidates.count >= 3 {
            for (i, c) in candidates.enumerated() {
                var others = candidates.map(\.value)
                others.remove(at: i)
                if let med = median(others), abs(c.value - med) > med * T.t41OutlierShare {
                    verdicts[c.id] = .rejected(.outlier)
                } else {
                    kept.append(c)
                }
            }
        } else {
            kept = candidates
        }

        let window = Array(kept.prefix(T.t41CalibrationWindow))
        let prior = BatteryCalibration.priorWhPerPct(packAh: packAh)
        guard let measured = median(window.map(\.value)) else {
            return (BatteryCalibration.prior(packAh: packAh), verdicts)
        }
        let n = window.count
        let need = T.t41CalibrationRides
        let value = n >= need ? measured : (prior * Double(need - n) + measured * Double(n)) / Double(need)
        var cal = BatteryCalibration(packAh: packAh, whPerPct: value, measuredWhPerPct: measured, ridesUsed: n,
                                     status: n >= need ? .calibrated : .learning)

        // M8 confirmation: the newest 3 rides that passed the single-ride rules all disagree by > 5 points
        if cal.isCalibrated {
            let recent = newestFirst.filter { r in
                switch evaluate(r, packAh: packAh) {
                case .used: return true
                case .rejected(let why): return why == .implausible
                }
            }.prefix(T.t41ConfirmRides)
            if recent.count == T.t41ConfirmRides {
                cal.checkSuggested = recent.allSatisfy { r in
                    guard let e = r.energyWhRaw, let s = r.startRestPct, let end = r.endRestPct ?? r.nextStartRestPct else { return false }
                    return abs(cal.usedPct(energyWhRaw: e) - (s - end)) > T.t41ConfirmPoints
                }
            }
        }
        return (cal, verdicts)
    }

    /// What the ride row should say for battery used under this calibration (M8): from energy once calibrated (the ride has
    /// energy and no gap > 1 min; S4 gap filling comes later), else the rested drop.
    public static func usedForRide(_ r: CalibrationRide, _ cal: BatteryCalibration) -> (usedPct: Double?, method: String?, energyWhCal: Double?) {
        if cal.isCalibrated, !r.isSimulated, let e = r.energyWhRaw, e > 0, r.longestGapS <= T.t41CalibrationMaxGapS {
            return (cal.usedPct(energyWhRaw: e), "calibrated", cal.energyWhCal(energyWhRaw: e))
        }
        if let a = r.startRestPct, let b = r.endRestPct { return (max(0, a - b), "rested", nil) }
        return (nil, nil, nil)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
