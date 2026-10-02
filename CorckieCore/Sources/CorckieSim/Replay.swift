import CorckieCore
import Foundation

/// Replays a recorded or synthetic event stream on a virtual clock (TESTING §2).
/// Tests call `runToEnd()`; the app calls `advance(realSeconds:)` from a timer at 1×–50×.
public final class ReplaySession {
    public let events: [TimedScooterEvent]
    public let clock: VirtualClock
    public private(set) var nextIndex = 0

    public init(events: [TimedScooterEvent], speed: Double = 1) {
        self.events = events.sorted { $0.t < $1.t }
        self.clock = VirtualClock(speed: speed)
        if let first = self.events.first { clock.jump(to: first.t) }
    }

    public var isFinished: Bool { nextIndex >= events.count }
    public var durationS: Double { (events.last?.t ?? 0) - (events.first?.t ?? 0) }
    public var progress: Double {
        guard durationS > 0, let first = events.first else { return isFinished ? 1 : 0 }
        return min(1, (clock.now - first.t) / durationS)
    }

    /// Moves the virtual clock by wall time × speed and returns the events now due.
    public func advance(realSeconds: Double) -> ArraySlice<TimedScooterEvent> {
        clock.advance(realSeconds: realSeconds)
        return due()
    }

    /// Everything that is left, at once (a 30-min ride in well under a second).
    public func runToEnd() -> ArraySlice<TimedScooterEvent> {
        if let last = events.last { clock.jump(to: last.t) }
        return due()
    }

    private func due() -> ArraySlice<TimedScooterEvent> {
        let start = nextIndex
        while nextIndex < events.count, events[nextIndex].t <= clock.now { nextIndex += 1 }
        return events[start..<nextIndex]
    }
}
