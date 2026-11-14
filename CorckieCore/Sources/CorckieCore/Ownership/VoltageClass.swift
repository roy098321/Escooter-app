import Foundation

/// D2 7c: the pack's voltage class (48 / 52 / 60 V) from one rested reading taken at full charge.
/// A full pack rests near 54.6 V (13 cells in series), 58.8 V (14) or 67.2 V (16).
public enum VoltageClass: Int, Sendable {
    case v48 = 48, v52 = 52, v60 = 60

    /// Below this a "full" reading is not a rested full pack (still charging, sagging or a partial charge)
    static let minFullV = 50.0
    static let maxFullV = 70.0

    /// nil when the reading cannot be a rested full pack
    public static func fromRestedFull(volts: Double) -> VoltageClass? {
        guard volts >= minFullV, volts <= maxFullV else { return nil }
        if volts < 56.7 { return .v48 }
        if volts < 63.0 { return .v52 }
        return .v60
    }

    public var text: String { "\(rawValue) V" }
}
