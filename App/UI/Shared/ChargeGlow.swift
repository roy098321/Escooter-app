import CorckieCore
import SwiftUI

// N7-6 (batch 7): a living battery glow while the charge timer runs. The scooter is off while charging, so the glow follows the
// timer (numbers stay estimate-style, "~"). A slow 8 s drifting orange glow; a green-gold settle when the timer says full, fading
// after about a minute. Places: Battery page top card (full), the Scooter tab photo card (orange rim), the Home charge line (faint).
// Reduce Motion: a still glow. Sunlight mode: no glow (the card already says "charging"). Dark mode: a deeper amber.

struct ChargeGlow: ViewModifier {
    enum Strength { case full, rim, faint }

    var session: ChargeSession?
    var nowMs: Int64
    var strength: Strength
    var radius: CGFloat = DS.Radius.card

    @Environment(\.sunlight) private var sunlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var drift = false

    /// nil = no glow; else the glow colour
    private var colour: Color? {
        guard let s = session, !sunlight else { return nil }
        let full = ChargeModel.fullMs(s)
        if nowMs >= full {
            return nowMs - full < 60_000 ? Color(red: 0.62, green: 0.78, blue: 0.30) : nil    // green-gold, then gone
        }
        return scheme == .dark ? Color(red: 0.85, green: 0.42, blue: 0.08) : Color(red: 0.98, green: 0.58, blue: 0.20)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if let c = colour, strength != .rim {
                if #available(iOS 18.0, *) {
                    // N7-6: a soft MeshGradient on iOS 18 (the middle point drifts with `drift`)
                    let o = strength == .full ? 0.55 : 0.30
                    MeshGradient(width: 3, height: 3,
                                 points: [[0, 0], [0.5, 0], [1, 0],
                                          [0, 0.5], [drift ? 0.7 : 0.3, drift ? 0.35 : 0.65], [1, 0.5],
                                          [0, 1], [0.5, 1], [1, 1]],
                                 colors: [.clear, c.opacity(o * 0.5), .clear,
                                          c.opacity(o * 0.6), c.opacity(o), c.opacity(o * 0.4),
                                          .clear, c.opacity(o * 0.5), .clear])
                        .blur(radius: 18)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    ZStack {
                        Circle().fill(c.opacity(strength == .full ? 0.55 : 0.30))
                            .frame(width: 180, height: 180)
                            .offset(x: drift ? 70 : -70, y: drift ? -20 : 20)
                        Circle().fill(c.opacity(strength == .full ? 0.40 : 0.20))
                            .frame(width: 140, height: 140)
                            .offset(x: drift ? -60 : 60, y: drift ? 25 : -25)
                    }
                    .blur(radius: strength == .full ? 40 : 28)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                }
            }
            .overlay {
                if let c = colour, strength == .rim {
                    shape.strokeBorder(c.opacity(drift ? 0.9 : 0.55), lineWidth: 2.5)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) { drift = true }
            }
    }
}

extension View {
    /// N7-6: the charging glow (nothing when not charging, in sunlight mode, or a minute after full)
    func chargeGlow(_ session: ChargeSession?, nowMs: Int64, _ strength: ChargeGlow.Strength, radius: CGFloat = DS.Radius.card) -> some View {
        modifier(ChargeGlow(session: session, nowMs: nowMs, strength: strength, radius: radius))
    }
}
