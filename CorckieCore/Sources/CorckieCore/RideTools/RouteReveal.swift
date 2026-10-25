import Foundation

/// B53 (owner 21 Oct, A4): after a ride the route draws itself over about a second, smoothly. The app draws it in screen space on a
/// display-rate timeline (one canvas, no map overlays re-added per step) and swaps to the real map line when done. This is the maths:
/// where each stretch ends along the route, the easing, and how much is visible at a moment. Reduce Motion: no draw, a plain fade.
public enum RouteReveal {
    public static let durationS = 1.0

    /// The share of the route's length reached at the end of each stretch (0...1, never going back); empty for nothing to draw
    public static func ends(_ stretches: [ValueStretch]) -> [Double] {
        var out: [Double] = []
        var total = 0.0
        for s in stretches {
            total += Geo.distanceM(s.a, s.b)
            out.append(total)
        }
        guard total > 0 else { return stretches.isEmpty ? [] : stretches.indices.map { Double($0 + 1) / Double(stretches.count) } }
        return out.map { $0 / total }
    }

    /// Ease in and out (smoothstep), 0...1
    public static func eased(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// Progress at `elapsed` seconds into the reveal
    public static func progress(elapsedS: Double, durationS: Double = durationS) -> Double {
        durationS > 0 ? eased(elapsedS / durationS) : 1
    }

    /// At `progress`: the stretches drawn whole, and how much of the next one (0...1)
    public static func visible(ends: [Double], progress: Double) -> (whole: Int, partial: Double) {
        guard !ends.isEmpty else { return (0, 0) }
        if progress >= 1 { return (ends.count, 0) }
        var whole = 0
        while whole < ends.count, ends[whole] <= progress { whole += 1 }
        guard whole < ends.count else { return (whole, 0) }
        let from = whole == 0 ? 0 : ends[whole - 1]
        let span = ends[whole] - from
        return (whole, span > 0 ? min(1, max(0, (progress - from) / span)) : 0)
    }
}
