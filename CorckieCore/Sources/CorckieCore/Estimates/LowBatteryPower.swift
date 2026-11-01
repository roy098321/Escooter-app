import Foundation

/// LBP (owner 27 Oct, FIN-2 → batch 102): learn per scooter the battery % below which the scooter starts holding back power (and so
/// top speed). Export 26 Oct: the power ceiling creeps down with the battery VOLTAGE, not with heat. It is learned only from rides that
/// went below ~15 % (calibration rides); until then nothing changes. Once learned: the battery page says so, the live arrival time counts
/// on slower riding below it, and V09 can say "power limit coming". Range is left as it is (the limit costs speed, not energy).
/// Pure, so it is tested on Linux.
public struct LBPSample: Equatable, Sendable {
    public var batteryPct: Int
    public var powerW: Double

    public init(batteryPct: Int, powerW: Double) {
        self.batteryPct = batteryPct
        self.powerW = powerW
    }
}

public struct LBPLearned: Codable, Equatable, Sendable {
    /// Below this battery % the power ceiling is lower
    public var belowPct: Int
    /// Ceiling there ÷ the usual ceiling (0...1)
    public var powerShare: Double

    public init(belowPct: Int, powerShare: Double) {
        self.belowPct = belowPct
        self.powerShare = powerShare
    }

    /// Top speed goes with the cube root of power at the same drag; the time of a stretch grows by its inverse
    public var timeFactor: Double { 1 / max(0.3, pow(powerShare, 1.0 / 3.0)) }
}

public enum LowBatteryPower {
    /// Learned only from rides that reached below this
    public static let deepPct = 15
    /// Battery steps of the ceiling
    public static let binPct = 5
    /// The usual ceiling comes from bins at or above this
    public static let usualFromPct = 30
    /// A bin whose ceiling is under this share of the usual one is "holding back"
    public static let holdShare = 0.88
    /// Readings a bin needs
    public static let minSamples = 20

    /// The 95th percentile of power in each 5 % battery bin (bin = its lower edge)
    public static func ceilings(_ samples: [LBPSample]) -> [Int: Double] {
        var bins: [Int: [Double]] = [:]
        for s in samples where s.powerW > 0 && s.batteryPct >= 0 && s.batteryPct <= 100 {
            bins[s.batteryPct / binPct * binPct, default: []].append(s.powerW)
        }
        var out: [Int: Double] = [:]
        for (k, v) in bins where v.count >= minSamples {
            let sorted = v.sorted()
            out[k] = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        return out
    }

    /// nil = not learned (no deep ride yet, or no hold-back seen)
    public static func learn(_ samples: [LBPSample]) -> LBPLearned? {
        guard samples.contains(where: { $0.batteryPct < deepPct }) else { return nil }
        let c = ceilings(samples)
        let usual = c.filter { $0.key >= usualFromPct }.map(\.value).sorted()
        guard !usual.isEmpty else { return nil }
        let base = usual[usual.count / 2]
        guard base > 0 else { return nil }
        // the highest bin under the usual range from which every lower bin with data is below the share
        let low = c.filter { $0.key < usualFromPct }.sorted { $0.key > $1.key }
        guard low.contains(where: { $0.key < deepPct }) else { return nil }
        var found: (pct: Int, share: Double)?
        for (k, v) in low {
            let share = v / base
            let lowerAllHold = low.filter { $0.key <= k }.allSatisfy { $0.value / base < holdShare }
            if share < holdShare, lowerAllHold {
                found = (k + binPct, (low.filter { $0.key <= k }.map(\.value).min() ?? v) / base)
                break
            }
        }
        guard let f = found else { return nil }
        return LBPLearned(belowPct: f.pct, powerShare: (f.share * 100).rounded() / 100)
    }

    /// The battery page's line
    public static func line(_ l: LBPLearned?) -> String {
        guard let l else { return "Low-battery power limit: not learned yet (needs a ride below \(deepPct)%)" }
        return "Below about \(l.belowPct)% your scooter holds back power (about \(Int((l.powerShare * 100).rounded()))% of usual)"
    }

    /// The live arrival time below the limit: the time still to ride stretched by the slower riding (1 above it)
    public static func timeFactor(batteryPct: Int?, learned: LBPLearned?) -> Double {
        guard let l = learned, let p = batteryPct, p < l.belowPct else { return 1 }
        return l.timeFactor
    }

    // MARK: Stored per scooter (UserDefaults JSON in the app)

    public static func key(scooterId: String) -> String { "corckie.lbp." + scooterId }

    public static func json(_ l: LBPLearned) -> Data? { try? JSONEncoder().encode(l) }
    public static func parse(_ d: Data?) -> LBPLearned? { d.flatMap { try? JSONDecoder().decode(LBPLearned.self, from: $0) } }
}

/// Made-up readings for the tests and the lab check (synthetic only): power spread up to a 600 W ceiling, 450 W below 25 %
public enum LBPSamples {
    public static func made(deep: Bool) -> [LBPSample] {
        var out: [LBPSample] = []
        let lowest = deep ? 8 : 20
        for pct in stride(from: 100, through: lowest, by: -1) {
            let ceiling: Double = pct < 25 ? 450 : 600
            for k in 0..<40 {
                let share: Double = Double(k) / 39
                out.append(LBPSample(batteryPct: pct, powerW: 100 + (ceiling - 100) * share))
            }
        }
        return out
    }
}
