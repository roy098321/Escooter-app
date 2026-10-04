import Foundation

/// T99 speed warning with hysteresis: on above 45 km/h, off below 43, so it never flickers around the
/// limit. The same rule runs on scooter speed and on GPS speed (phone mode, P3 D3).
public struct SpeedWarning: Equatable, Sendable {
    public private(set) var isOn = false
    public let onAboveKmh: Double
    public let clearBelowKmh: Double

    public init(onAboveKmh: Double = T.t99SlowKmh, clearBelowKmh: Double = T.t99ClearKmh) {
        self.onAboveKmh = onAboveKmh
        self.clearBelowKmh = clearBelowKmh
    }

    /// Feed the speed that is shown; returns whether the warning is on now.
    @discardableResult
    public mutating func update(speedKmh: Double) -> Bool {
        if isOn {
            if speedKmh < clearBelowKmh { isOn = false }
        } else if speedKmh > onAboveKmh {
            isOn = true
        }
        return isOn
    }

    public mutating func reset() { isOn = false }
}
