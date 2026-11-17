import CoreHaptics
import CorckieCore
import Foundation

/// N7-4 (batch 7), owner's pick B "speed texture": while the route draws itself, one continuous buzz whose strength follows the
/// ride's speed (silent at stops), ending in the app's success thump. Same length as the line and the sound (`RouteDraw`).
/// Off when Settings → Sounds → Vibration is off, on phones without Core Haptics, and with Reduce Motion (no intro then).
@MainActor
final class RideDrawHaptic {
    static let shared = RideDrawHaptic()
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?

    func play(speedsKmh: [Double], durationS: Double) {
        guard !Haptics.muted, CHHapticEngine.capabilitiesForHardware().supportsHaptics, !speedsKmh.isEmpty else { return }
        do {
            if engine == nil {
                let e = try CHHapticEngine()
                e.isAutoShutdownEnabled = true
                engine = e
            }
            try engine?.start()
            let steps = 24
            let levels = RouteDraw.hapticIntensities(speedsKmh: speedsKmh, steps: steps)
            let buzz = CHHapticEvent(eventType: .hapticContinuous,
                                     parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                  CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)],
                                     relativeTime: 0, duration: durationS)
            let points = levels.enumerated().map { i, v in
                CHHapticParameterCurve.ControlPoint(relativeTime: durationS * Double(i) / Double(steps), value: Float(v * 0.6))
            }
            let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: points, relativeTime: 0)
            let thump = CHHapticEvent(eventType: .hapticTransient,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                                      relativeTime: durationS + 0.05)
            let pattern = try CHHapticPattern(events: [buzz, thump], parameterCurves: [curve])
            player = try engine?.makeAdvancedPlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            Log.error(source: "haptics", "ride draw: \(error.localizedDescription)")
        }
    }
}
