import Foundation

/// R2 (hotfix 02, owner 26 Oct): on the Battery layer a small labelled marker ("90%", "80%", …) where the battery FIRST dropped below
/// each multiple of 10 during the ride. The samples carry the filtered / settled battery (B56 + B54); only the first crossing of
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
    public static func marks(_ points: [SeriesPoint]) -> [BatteryMark] {
        guard let start = points.first(where: { $0.batteryPct != nil })?.batteryPct else { return [] }
        var out: [BatteryMark] = []
        var done = Set<Int>()
        var lastFix: GeoPoint?
        for p in points {
            if p.hasFix, let g = p.point { lastFix = g }
            guard let b = p.batteryPct else { continue }
            // every level L (a multiple of 10 below the start) that this reading is under, first time only
            var level = (start - 1) / 10 * 10
            while level > b, level > 0 {
                if !done.contains(level) {
                    done.insert(level)
                    if let g = (p.hasFix ? p.point : nil) ?? lastFix { out.append(BatteryMark(point: g, level: level)) }
                }
                level -= 10
            }
        }
        return out.sorted { $0.level > $1.level }
    }
}
