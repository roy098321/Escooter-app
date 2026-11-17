import Foundation

/// N7-4 / N7-12 (batch 7): the "route draws itself" intro. ONE length for the line, the counters, the replay sound and the speed
/// haptic: clamp(0.6 + 0.4 · ln(1 + km / 2), 0.6 s, 1.8 s) → 2 km ≈ 0.9 s, 8 km ≈ 1.2 s, 30 km ≈ 1.7 s. It plays after a ride ends
/// and on the first open of each ride, never on a re-open; Reduce Motion shows everything at once.
public enum RouteDraw {
    public static let minS = 0.6
    public static let maxS = 1.8

    public static func durationS(km: Double) -> Double {
        let d = 0.6 + 0.4 * log(1 + max(0, km) / 2)
        return min(maxS, max(minS, d))
    }

    /// The setting key that remembers a ride's intro already played
    public static func seenKey(rideId: String) -> String { "routeDraw.seen.\(rideId)" }

    /// The speed texture of the haptic: one intensity (0...1) per step along the ride, 0 at stops (below 3 km/h), the
    /// fastest stretch 1. `speedsKmh` are the ride's speeds in order; `steps` how many haptic events the intro has.
    public static func hapticIntensities(speedsKmh: [Double], steps: Int) -> [Double] {
        guard steps > 0, !speedsKmh.isEmpty else { return [] }
        let top = max(speedsKmh.max() ?? 0, 1)
        return (0..<steps).map { i in
            let idx = min(speedsKmh.count - 1, Int(Double(i) / Double(steps) * Double(speedsKmh.count)))
            let v = speedsKmh[idx]
            return v < 3 ? 0 : min(1, max(0.15, v / top))
        }
    }
}
