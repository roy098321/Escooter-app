import Foundation

/// R2 (hotfix 02, owner 26 Oct): on the Battery layer a small labelled marker ("90%", "80%", …) where the battery FIRST reached
/// each multiple of 10 during the ride (batch 4, B88: the smoothed level, the voice's rule). The samples carry the filtered / settled battery (B56 + B54); only the first crossing of
/// each level counts, so a 90 ↔ 89 flicker gives one mark; no mark for the starting level itself.
public struct BatteryMark: Equatable, Sendable {
    public var point: GeoPoint
    public var level: Int

    public init(point: GeoPoint, level: Int) {
        self.point = point
        self.level = level
    }

    /// "90%"
    public var text: String { "\(level)%" }
}

public enum BatteryMarks {
    /// B88 (batch 4): the SAME rule as the voice's "Battery at N percent": the smoothed (sag-proof) level first reaches N
    /// (`RideBatteryLevel` + `TenPercentRule`), so the pill sits where the voice spoke. A ride without power readings uses its
    /// readings as they are. - whPerPct: Wh per 1 % (CalibrationUpdater; the prior without one)
    public static func marks(_ points: [SeriesPoint], whPerPct: Double = BatteryCalibration.prior().whPerPct) -> [BatteryMark] {
        var level = RideBatteryLevel()
        var out: [BatteryMark] = []
        var lastFix: GeoPoint?
        for p in points.sorted(by: { $0.t < $1.t }) {
            if p.hasFix, let g = p.point { lastFix = g }
            let reached = level.update(t: p.t, livePct: p.batteryPct.map(Double.init), powerW: p.powerW, currentA: nil,
                                       speedKmh: p.speedKmh, whPerPct: whPerPct)
            guard !reached.isEmpty, let g = (p.hasFix ? p.point : nil) ?? lastFix else { continue }
            for n in reached { out.append(BatteryMark(point: g, level: n)) }
        }
        return out.sorted { $0.level > $1.level }
    }
}
