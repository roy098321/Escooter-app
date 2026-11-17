import Foundation

/// Batch 6/7 motion rule (N6-3..N6-6, N7): every new movement is a spring, and with Reduce Motion on it becomes a short fade.
/// Pure, so the rule is tested on Linux; the SwiftUI views pick their animation and transition from it.
public enum MotionStyle: Equatable, Sendable {
    case spring
    case fade

    public static func pick(reduceMotion: Bool) -> MotionStyle { reduceMotion ? .fade : .spring }

    /// the fade's length (s)
    public static let fadeS = 0.2
}
