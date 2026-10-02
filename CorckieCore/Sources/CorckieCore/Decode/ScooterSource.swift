import Foundation

/// What a scooter source reports: the real link (ScooterLink) and the fake scooter (CorckieSim)
/// speak the same language, so the decoder and ride engine can't tell them apart (TESTING §2).
public enum ScooterEvent: Equatable, Sendable {
    case connected
    case packet([UInt8])
    case disconnected
}

/// An event at a time in seconds (from the start of a log, or a virtual clock).
public struct TimedScooterEvent: Equatable, Sendable {
    public var t: Double
    public var event: ScooterEvent

    public init(t: Double, event: ScooterEvent) {
        self.t = t
        self.event = event
    }

    public var bytes: [UInt8]? {
        if case .packet(let b) = event { return b }
        return nil
    }
}
