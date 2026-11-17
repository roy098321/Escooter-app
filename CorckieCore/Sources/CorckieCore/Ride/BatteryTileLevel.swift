import Foundation

/// N8-2 (batch 8): the live battery tile's colour, silent: the number and a thin border turn amber at 20 % or less and red at 10 % or
/// less, on the SAME smoothed % the tile shows (D-PR-09, so a load dip never flickers it). The tile never fills with colour.
/// Colour-blind mode adds a ▼ before the number. The 20 / 15 / 10 % voice lines are unchanged.
public enum BatteryTileLevel: Equatable, Sendable {
    case normal, low, critical

    public static let lowAtPct = 20
    public static let criticalAtPct = 10

    public static func level(pct: Int?) -> BatteryTileLevel {
        guard let p = pct else { return .normal }
        if p <= criticalAtPct { return .critical }
        if p <= lowAtPct { return .low }
        return .normal
    }

    /// "▼ 18%" in colour-blind mode when low or critical
    public static func number(_ text: String, level: BatteryTileLevel, colourBlind: Bool) -> String {
        colourBlind && level != .normal ? "\u{25BC} " + text : text
    }
}
