import Foundation

/// Virtual clock for the fake scooter (TESTING §2): tests jump straight to the end;
/// the app advances it from a real timer at 1×, 5×, 20× or 50×.
public final class VirtualClock {
    public static let appSpeeds: [Double] = [1, 5, 20, 50]

    /// Seconds since the start of the replay.
    public private(set) var now: Double = 0
    public var speed: Double

    public init(speed: Double = 1) {
        self.speed = speed
    }

    /// Moves the clock by `realSeconds` of wall time × speed; returns the new time.
    @discardableResult
    public func advance(realSeconds: Double) -> Double {
        now += max(0, realSeconds) * speed
        return now
    }

    /// Jumps to a virtual time (never backwards).
    public func jump(to time: Double) {
        now = max(now, time)
    }

    public func reset() {
        now = 0
    }
}
