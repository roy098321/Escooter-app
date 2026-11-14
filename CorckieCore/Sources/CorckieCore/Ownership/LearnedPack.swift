import Foundation

/// D2 7e: the battery size (Ah) learned from the rider's own calibration: Wh per 1 % x 100 / pack voltage.
/// Until the calibration is settled the app says "Assumed 16 Ah"; afterwards "16 Ah · learned from 5 rides".
public enum LearnedPack {
    /// A learned value within this share of a common size snaps to that size (the scooter's sticker says 15 or 16, not 17.3)
    static let snapShare = 0.12

    public static func ah(whPerPct: Double, packV: Double = T.t42PackVoltage) -> Double {
        whPerPct * 100 / packV
    }

    /// The common size the raw value is closest to, or the nearest whole Ah when none is close
    public static func snapped(_ raw: Double, choices: [Double] = SettingsCatalog.packChoices) -> Double {
        if let c = choices.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(c - raw) / c <= snapShare { return c }
        return raw.rounded()
    }

    public static func line(_ cal: BatteryCalibration) -> String {
        let assumed = Int(cal.packAh.rounded())
        guard cal.status == .calibrated, let measured = cal.measuredWhPerPct, measured > 0 else {
            return "Assumed \(assumed) Ah"
        }
        let learned = Int(snapped(ah(whPerPct: measured)))
        return "\(learned) Ah \u{00B7} learned from \(cal.ridesUsed) rides"
    }
}
