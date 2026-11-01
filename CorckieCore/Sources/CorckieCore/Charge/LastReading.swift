import Foundation

/// R3 / B64 + R5 / B65 (hotfix 02, owner 26 Oct): with the scooter off, Home tells the LAST battery reading and when it was
/// ("66% · 07:49"), and the charge estimate starts from that same reading. The settled reading at the end of the last ride wins
/// over the last-seen value written around the same time (that one can still carry the dip of riding: 62 % against a resting 66 %).
public struct BatteryReading: Equatable, Sendable {
    public var pct: Int
    public var ms: Int64

    public init(pct: Int, ms: Int64) {
        self.pct = pct
        self.ms = ms
    }
}

public enum LastReading {
    /// A last-seen value this close after the ride's end belongs to the same stop: the ride's resting reading wins
    public static let sameStopMs: Int64 = 15 * 60_000

    public static func pick(seen: BatteryReading?, rideEnd: BatteryReading?) -> BatteryReading? {
        guard let r = rideEnd else { return seen }
        guard let s = seen else { return r }
        return s.ms - r.ms <= sameStopMs ? r : s
    }

    /// "66% · 07:49"
    public static func text(_ r: BatteryReading, utcOffsetMin: Int) -> String {
        "\(r.pct)% \u{00B7} \(ChargeText.clock(r.ms, utcOffsetMin: utcOffsetMin))"
    }
}

extension PlugAlert {
    /// R3: the target pill says what it is: "Charge to 100%" / "Charge to 15 km"
    public var targetText: String { "Charge to \(pillText)" }
}
