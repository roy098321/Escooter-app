import CorckieCore
import SwiftUI

/// N8-1 (batch 8): the warning-light strip: small car-style icons in a row (red / amber / blue), icons only while riding. At a stop
/// (wheel speed 0 for 1 s) a tap expands one icon sideways into its line: a light tick, a ~0.3 s spring with no bounce, the others
/// fade; it folds back after 4 s, on a second tap, or at once when the wheel turns. One open at a time. Reduce Motion: a fade.
/// While moving a tap does nothing.
struct WarningStripView: View {
    let lights: [WarningLight]
    let expandable: Bool
    @State private var open: WarningLight?
    @State private var foldToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sunlight) private var sunlight

    var body: some View {
        HStack(spacing: 8) {
            ForEach(lights, id: \.self) { w in
                light(w)
                    .opacity(open == nil || open == w ? 1 : 0.25)
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? .easeInOut(duration: MotionStyle.fadeS) : .spring(response: 0.3, dampingFraction: 1), value: open)
        .onChange(of: expandable) { _, can in if !can { open = nil } }     // the wheel turns: fold at once
        .onChange(of: lights) { _, now in if let o = open, !now.contains(o) { open = nil } }
    }

    private func colour(_ w: WarningLight) -> Color {
        switch w.colour {
        case .red: return .red
        case .amber: return .orange
        case .blue: return Color(red: 0.25, green: 0.55, blue: 0.95)
        }
    }

    private func light(_ w: WarningLight) -> some View {
        let isOpen = open == w
        return Button {
            guard expandable else { return }      // moving: nothing
            Haptics.tick()
            open = isOpen ? nil : w
            foldToken += 1
            let token = foldToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if foldToken == token { open = nil } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: w.symbol)
                    .font(.title3.weight(.semibold))
                    .motorHotWiggle(w == .motorVeryHot)      // N7-5 moved onto the strip
                if isOpen {
                    Text(w.line).font(.headline).lineLimit(1).fixedSize()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(sunlight ? colour(w) : .white)
            .padding(.horizontal, 12)
            .frame(minWidth: 48, minHeight: 44)
            .background(sunlight ? Color(.systemBackground) : colour(w).opacity(0.85), in: Capsule())
            .overlay { if sunlight { Capsule().strokeBorder(colour(w), lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(w.line)
    }
}
