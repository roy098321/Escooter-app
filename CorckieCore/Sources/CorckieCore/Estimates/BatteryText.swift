import Foundation

// M3-04: the words of the Battery page, kept here so they can be tested on Linux. Honest numbers only.

public enum BatteryText {
    /// "Learning, 3 of 5 rides" / "Calibrated on 7 rides" / "Not started: using the 16 Ah pack"
    public static func calibrationStatus(_ cal: BatteryCalibration) -> String {
        switch cal.status {
        case .prior: return "Not started, using the \(Int(cal.packAh.rounded())) Ah pack until the first good ride"
        case .learning: return "Learning, \(cal.ridesUsed) of \(T.t41CalibrationRides) rides"
        case .calibrated: return "Calibrated on \(cal.ridesUsed) rides"
        }
    }

    /// "8.3 Wh per 1% (about 827 Wh usable)"
    public static func calibrationValue(_ cal: BatteryCalibration) -> String {
        String(format: "%.1f Wh per 1%% (about %ld Wh usable)", cal.whPerPct, Int(cal.usableWh.rounded()))
    }

    /// One charge-log line. `start` / `end` are the already formatted window times ("Tue 18:10").
    /// "+46% charged between Tue 18:10 and Wed 08:05" / "Charged while away · 23% → 100% · time unknown"
    public static func chargeLine(fromPct: Double, toPct: Double, away: Bool, start: String, end: String) -> String {
        let from = Int(fromPct.rounded()), to = Int(toPct.rounded())
        if away { return "Charged while away · \(from)% → \(to)% · time unknown" }
        return "+\(max(0, to - from))% charged between \(start) and \(end)"
    }

    public static func cyclesText(_ cycles: Double) -> String {
        String(format: "%.1f", cycles)
    }

    /// "Gathering data" / baseline / "92%"
    public static func healthTitle(_ s: BatteryHealth.State) -> String {
        switch s {
        case .gathering: return "Gathering data"
        case .baseline: return "Baseline forming"
        case let .health(pct, _, _): return "\(Int(pct.rounded()))%"
        }
    }

    public static func healthDetail(_ s: BatteryHealth.State) -> String {
        switch s {
        case let .gathering(cycles, rides):
            let c = String(format: "%.1f", cycles)
            return "Needs \(Int(BatteryHealth.minCycles)) charge cycles and \(BatteryHealth.minRides) rides. So far \(c) cycles and \(rides) ride\(rides == 1 ? "" : "s")."
        case let .baseline(km):
            return "About \(Int(km.rounded())) km on a full battery so far. The trend starts once there are 3 months to compare."
        case let .health(_, now, first):
            return "About \(Int(now.rounded())) km on a full battery now, against \(Int(first.rounded())) km in the first 3 months. Since tracking started."
        }
    }
}
