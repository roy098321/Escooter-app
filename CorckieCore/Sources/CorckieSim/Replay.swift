import CorckieCore
import Foundation

/// Replays a recorded or synthetic event stream on a virtual clock (TESTING §2).
/// Tests call `runToEnd()`; the app calls `advance(realSeconds:)` from a timer at 1×–50×.
public final class ReplaySession {
    public let events: [TimedScooterEvent]
    /// Phone GPS / barometer / markers on the same clock (M1-02); empty for scooter-only replays
    public let phoneEvents: [TimedPhoneEvent]
    public let clock: VirtualClock
    public private(set) var nextIndex = 0
    public private(set) var nextPhoneIndex = 0

    public init(events: [TimedScooterEvent], phoneEvents: [TimedPhoneEvent] = [], speed: Double = 1) {
        self.events = events.sorted { $0.t < $1.t }
        self.phoneEvents = phoneEvents.sorted { $0.t < $1.t }
        self.clock = VirtualClock(speed: speed)
        if let first = self.events.first { clock.jump(to: first.t) }
    }

    public convenience init(stream: SimStream, speed: Double = 1) {
        self.init(events: stream.scooter, phoneEvents: stream.phone, speed: speed)
    }

    /// Finished when the scooter stream AND the phone stream have been delivered
    public var isFinished: Bool { nextIndex >= events.count && nextPhoneIndex >= phoneEvents.count }
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

    /// Moves the clock like `advance` and returns the scooter AND the phone events now due.
    public func advanceAll(realSeconds: Double) -> (scooter: ArraySlice<TimedScooterEvent>, phone: ArraySlice<TimedPhoneEvent>) {
        clock.advance(realSeconds: realSeconds)
        return (due(), duePhone())
    }

    /// Everything that is left, at once (a 30-min ride in well under a second).
    public func runToEnd() -> ArraySlice<TimedScooterEvent> {
        if let last = events.last { clock.jump(to: max(last.t, clock.now)) }
        return due()
    }

    /// Everything that is left on both streams, at once.
    public func runToEndAll() -> (scooter: ArraySlice<TimedScooterEvent>, phone: ArraySlice<TimedPhoneEvent>) {
        clock.jump(to: max(events.last?.t ?? 0, phoneEvents.last?.t ?? 0, clock.now))
        return (due(), duePhone())
    }

    private func duePhone() -> ArraySlice<TimedPhoneEvent> {
        let start = nextPhoneIndex
        while nextPhoneIndex < phoneEvents.count, phoneEvents[nextPhoneIndex].t <= clock.now { nextPhoneIndex += 1 }
        return phoneEvents[start..<nextPhoneIndex]
    }

    private func due() -> ArraySlice<TimedScooterEvent> {
        let start = nextIndex
        while nextIndex < events.count, events[nextIndex].t <= clock.now { nextIndex += 1 }
        return events[start..<nextIndex]
    }
}
