import CorckieCore
import Foundation

/// Riding asks (option b): which ask stands (speed + since when), when the last one was done, and the stretches the rider said
/// "Not here" to, in UserDefaults (nothing leaves the phone). Compiled into AppTests with the insight loader.
enum RidingAskState {
    static let stateKey = "corckie.asks.state"
    static let doneKey = "corckie.asks.doneAtMs"
    static let notHereKey = "corckie.asks.notHere"
    /// "Got it ✓" stays this long after the ask was done
    static let gotItMs: Int64 = 24 * 3_600_000

    static var notHere: Set<String> { Set(UserDefaults.standard.stringArray(forKey: notHereKey) ?? []) }

    static func addNotHere(_ key: String) {
        var s = notHere
        s.insert(key)
        UserDefaults.standard.set(Array(s), forKey: notHereKey)
    }

    /// Puts the ask (and "Got it ✓") on the speed graph's card
    static func apply(_ insights: [RideLevelInsight], rides: [RideLevelRide], stretches: [StretchPoint], routes: [AskRoutePath],
                      nowMs: Int64) -> [RideLevelInsight] {
        guard let i = insights.firstIndex(where: { $0.topic == .speedCost }) else { return insights }
        var out = insights
        let d = UserDefaults.standard
        let skip = notHere
        // the standing ask: done now?
        if let st = d.array(forKey: stateKey) as? [Double], st.count == 2 {
            let speed = Int(st[0])
            let m = RidingAsks.metres(speedKmh: st[0])
            if RidingAsks.done(RidingAsk(speedKmh: speed, metres: m, stretch: nil), since: Int64(st[1]), stretches: stretches) {
                d.set(Double(nowMs), forKey: doneKey)
                d.removeObject(forKey: stateKey)
            }
        }
        let xs = rides.compactMap(\.avgKmh) + stretches.map(\.speedKmh)
        let topic = RideLevelInsight.Topic.speedCost
        if let ask = RidingAsks.ask(covered: RideLevelInsights.covered(topic, xs: xs), wanted: topic.wanted, routes: routes, notHere: skip) {
            let stored = d.array(forKey: stateKey) as? [Double]
            if stored == nil || Int(stored?[0] ?? -1) != ask.speedKmh { d.set([Double(ask.speedKmh), Double(nowMs)], forKey: stateKey) }
            out[i].ask = ask
            out[i].askStretches = RidingAsks.stretches(routes, metres: ask.metres, notHere: skip)
        }
        if let done = d.object(forKey: doneKey) as? Double, nowMs - Int64(done) < gotItMs { out[i].askDone = true }
        return out
    }
}
