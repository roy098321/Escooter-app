import SwiftUI

// N7-5 (batch 7): icons that react. One rule: an icon moves only on a real change, once; only "charging" and "searching" loop
// while true; nothing moves at idle; Reduce Motion: no movement at all. iOS 17 SF Symbol effects; iOS 18 ones (wiggle, rotate)
// fall back to a bounce on iOS 17.

private struct ReduceMotionGate<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V
    let kind: Kind

    enum Kind { case bounce, bounceDown, wiggle, quarterTurn }

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            switch kind {
            case .bounce: content.symbolEffect(.bounce, value: value)
            case .bounceDown: content.symbolEffect(.bounce.down, value: value)
            case .wiggle:
                if #available(iOS 18.0, *) { content.symbolEffect(.wiggle, value: value) } else { content.symbolEffect(.bounce, value: value) }
            case .quarterTurn:
                if #available(iOS 18.0, *) { content.symbolEffect(.rotate, value: value) } else { content.symbolEffect(.bounce, value: value) }
            }
        }
    }
}

private struct LoopWhile: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    let searching: Bool

    func body(content: Content) -> some View {
        if searching {
            content.symbolEffect(.variableColor.iterative, options: .repeating, isActive: active && !reduceMotion)
        } else {
            content.symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
        }
    }
}

extension View {
    /// one bounce when `value` changes (a real change: connected, cargo picked, tab chosen, saved)
    func bounceOnce<V: Equatable>(_ value: V) -> some View { modifier(ReduceMotionGate(value: value, kind: .bounce)) }
    /// the Start squish on press
    func squishOnce<V: Equatable>(_ value: V) -> some View { modifier(ReduceMotionGate(value: value, kind: .bounceDown)) }
    /// the motor-hot wiggle: once when the heat warning appears. Reusable on the Batch 8 warning-light icon.
    func motorHotWiggle<V: Equatable>(_ value: V) -> some View { modifier(ReduceMotionGate(value: value, kind: .wiggle)) }
    /// the Settings gear turns a little as it opens
    func turnOnce<V: Equatable>(_ value: V) -> some View { modifier(ReduceMotionGate(value: value, kind: .quarterTurn)) }
    /// charging: a slow pulse while plugged in
    func pulseWhile(_ active: Bool) -> some View { modifier(LoopWhile(active: active, searching: false)) }
    /// searching for the scooter: the waves fill one by one
    func searchingWhile(_ active: Bool) -> some View { modifier(LoopWhile(active: active, searching: true)) }
}
