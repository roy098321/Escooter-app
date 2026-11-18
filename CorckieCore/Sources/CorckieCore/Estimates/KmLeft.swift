import Foundation

/// A-14 / A-15 / A-16 (batch 9, owner 18 Nov): ONE "km left" number for the live battery tile, the voice lines and the ride summary.
/// It is the Battery page's real range (`RealRangeCalc`, your recent %/km and the reserve) at a battery level: during a ride the
/// smoothed level (D-PR-09), on the summary the ride's end level. Whole km, rounded down (no extra margin, P-1). nil = no real range
/// yet ("learning range"), switching to km by itself once rides give one.
public enum KmLeft {
    public static func km(levelPct: Double?, pctPerKm: Double?, reservePct: Double) -> Int? {
        guard let level = levelPct, let rate = pctPerKm, rate > 0 else { return nil }
        return max(0, Int(((level - reservePct) / rate + 1e-9).rounded(.down)))
    }

    /// The same, from the Battery page's real range
    public static func km(levelPct: Double?, range: RealRange?) -> Int? {
        km(levelPct: levelPct, pctPerKm: range?.pctPerKm, reservePct: range?.reservePct ?? T.t80ReserveDefaultPct)
    }

    /// Live battery tile, the small second line: "≈ 18 km left" / "learning range"
    public static func tileText(_ km: Int?) -> String { km.map { "\u{2248} \($0) km left" } ?? "learning range" }

    /// VoiceOver for that line
    public static func spokenText(_ km: Int?) -> String { km.map { "About \($0) kilometres left" } ?? "Range still learning" }

    /// Ride summary tile value: "≈ 18 km" / "learning"
    public static func summaryText(_ km: Int?) -> String { km.map { "\u{2248} \($0) km" } ?? "learning" }
}
