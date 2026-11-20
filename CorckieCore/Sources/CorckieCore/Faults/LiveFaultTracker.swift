import Foundation

/// N10-2 / N10-3 (batch 10): the same F2 / F3 rules as FaultDetectors, frame by frame during the ride, so the voice can speak at
/// the right moment: a power cut the moment it happens, a brake run right after the braking ends.
public struct LiveFaultTracker: Sendable {
    public enum Event: Equatable, Sendable { case powerCut, brakeRunEnded }

    var prev: ScooterFrame?
    var runStart: Double?
    var runLast: Double?

    public init() {}

    public mutating func frame(_ f: ScooterFrame) -> [Event] {
        var out: [Event] = []
        if f.shuttingDown, prev?.shuttingDown == false, let s = prev?.speedKmh, s > FaultDetectors.f2MinKmh { out.append(.powerCut) }
        let on = f.brake && (f.currentA ?? 0) > FaultDetectors.f3MinA
        if let l = runLast, f.t - l > FaultDetectors.f3MaxGapS { if closeRun() { out.append(.brakeRunEnded) } }
        if on {
            if runStart == nil { runStart = f.t }
            runLast = f.t
        } else if runStart != nil {
            if closeRun() { out.append(.brakeRunEnded) }
        }
        prev = f
        return out
    }

    mutating func closeRun() -> Bool {
        defer { runStart = nil; runLast = nil }
        guard let s = runStart, let l = runLast else { return false }
        return l - s >= FaultDetectors.f3MinS
    }
}
