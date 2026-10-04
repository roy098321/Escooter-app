import Foundation

/// M1-11: when the scooter was last seen, and its battery then, for Home's greyed "last seen 18:02 · 58%" (pattern L).
/// Kept in UserDefaults (two numbers); written at most every 30 s while packets arrive, and at the disconnect.
enum LastSeen {
    private static let timeKey = "corckie.lastSeenMs"
    private static let pctKey = "corckie.lastSeenPct"
    private static var lastWrite = Date.distantPast

    static func note(batteryPct: Int?, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWrite) >= 30 else { return }
        lastWrite = now
        let d = UserDefaults.standard
        d.set(Int(now.timeIntervalSince1970 * 1000), forKey: timeKey)
        if let p = batteryPct { d.set(p, forKey: pctKey) }
    }

    static func load() -> (ms: Int64?, pct: Int?) {
        let d = UserDefaults.standard
        let ms = d.object(forKey: timeKey) as? Int
        let pct = d.object(forKey: pctKey) as? Int
        return (ms.map(Int64.init), pct)
    }
}

/// Onboarding is shown once (Developer → Show onboarding runs it again).
enum OnboardingState {
    private static let key = "corckie.onboardingDone"
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
