import CorckieCore
import Foundation

/// Riding asks (option b): which ask stands (speed + since when), when the last one was done, and the stretches the rider said
/// "Not here" to, in UserDefaults (nothing leaves the phone). Compiled into AppTests with the insight loader.
enum RidingAskState {
    static let stateKey = "corckie.asks.state"
    static let doneKey = "corckie.asks.doneAtMs"
    static let notHereKey = "corckie.asks.notHere"
    /// N4-2 B: the stretch the voice cue watches for: [speed, metres, start lat, start lon, end lat, end lon]
    static let cueKey = "corckie.asks.cue"
    /// "Got it ✓" stays this long after the ask was done
    static let gotItMs: Int64 = 24 * 3_600_000

    static var notHere: Set<String> { Set(UserDefaults.standard.stringArray(forKey: notHereKey) ?? []) }

    static func addNotHere(_ key: String) {
        var s = notHere
        s.insert(key)
        UserDefaults.standard.set(Array(s), forKey: notHereKey)
        UserDefaults.standard.removeObject(forKey: cueKey)     // N4-2 B: never cue a stretch the rider turned down
    }

    /// N4-2 B: the cue for the next ride (nil = no ask with a stretch)
    static var cue: AskCue? {
        guard let v = UserDefaults.standard.array(forKey: cueKey) as? [Double], v.count == 6 else { return nil }
        return AskCue(speedKmh: Int(v[0]), metres: Int(v[1]), start: GeoPoint(lat: v[2], lon: v[3]), end: GeoPoint(lat: v[4], lon: v[5]))
    }

    private static func storeCue(_ ask: RidingAsk) {
        guard let s = ask.stretch, let a = s.start, let b = s.end else {
            UserDefaults.standard.removeObject(forKey: cueKey)
            return
        }
        UserDefaults.standard.set([Double(ask.speedKmh), Double(ask.metres), a.lat, a.lon, b.lat, b.lon], forKey: cueKey)
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
            storeCue(ask)
        }
        if let done = d.object(forKey: doneKey) as? Double, nowMs - Int64(done) < gotItMs { out[i].askDone = true }
        return out
    }
}
