import Foundation

// MARK: F-38 - a ride ends at its last movement

/// F-38 (owner 22 Oct, note 7a, A; dilemma D-PR-06): a ride's end time is its last movement, not the moment the app closed it
/// (scooter off, 10 min standing, a relaunch); Time = start to last movement, so stops inside the ride still count.
/// The engine already ends at `lastMoveT`; this is the same rule for a ride closed from its stored samples only.
public enum RideEndTime {
    /// The last moving sample's time (s from the ride start) by the samples' own flags / speeds; nil = never moved.
    public static func endS(_ samples: [RideSample]) -> Double? {
        let sorted = samples.sorted { $0.t < $1.t }
        let moving = RideMetricsCalculator.movingFlags(sorted)
        return moving.lastIndex(of: true).map { sorted[$0].t }
    }

    /// Time of a ride (F-38): first movement to last movement, stops inside included, s.
    public static func timeS(firstMoveS: Double?, lastMoveS: Double?) -> Double? {
        guard let a = firstMoveS, let b = lastMoveS, b >= a else { return nil }
        return b - a
    }
}
