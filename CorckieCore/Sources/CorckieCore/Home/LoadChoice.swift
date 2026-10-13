import Foundation

/// F-02: the Load selector on Home (None / Light / Heavy / exact kg). The choice waits for the **next** ride and is attached to it when
/// it starts, then it resets to None. Stored as one short text; same levels as the Loaded tag (M4-05, `LoadLevel`).
public struct LoadChoice: Equatable, Sendable {
    public var level: LoadLevel
    /// Only for `.custom`
    public var customKg: Double

    public static let empty = LoadChoice(level: .none, customKg: 0)
    public static let maxKg = 100.0

    public init(level: LoadLevel, customKg: Double = 0) {
        self.level = level
        self.customKg = customKg
    }

    /// "none", "light", "heavy" or "custom:7.5"
    public var stored: String { level == .custom ? "custom:\(customKg)" : level.rawValue }

    public init?(stored: String?) {
        guard let stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix("custom:") {
            guard let kg = Double(stored.dropFirst("custom:".count)), kg >= 0, kg <= Self.maxKg else { return nil }
            self.init(level: .custom, customKg: kg)
            return
        }
        guard let level = LoadLevel(rawValue: stored), level != .custom else { return nil }
        self.init(level: level)
    }

    /// What is attached to the ride: the level and the kg, or nil for None (nothing is tagged, as before).
    /// `lightKg` / `heavyKg` are the Settings load levels (5 and 15 unless changed).
    public func attachment(lightKg: Double, heavyKg: Double) -> (level: LoadLevel, kg: Double)? {
        switch level {
        case .none: return nil
        case .light: return (.light, lightKg)
        case .heavy: return (.heavy, heavyKg)
        case .custom: return customKg > 0 ? (.custom, customKg) : nil
        }
    }
}
