import CorckieCore
import SwiftUI

/// F-33: one horizontal row of layer buttons over the ride map: Speed · Hills · Wind · Battery · Temp. Tapping the active button again
/// switches it to its derived view (the label changes: Speed → Steady …); the legend title and colour bar follow.
struct LayerRow: View {
    let layers: [MapLayer]
    @Binding var view: LayerView

    var body: some View {
        HStack(spacing: 0) {
            ForEach(layers, id: \.self) { layer in
                let on = layer == view.layer
                let label = on ? view.buttonLabel : LayerView(layer).buttonLabel
                Button {
                    Haptics.tick()
                    view = view.tapped(layer)
                } label: {
                    Text(label)
                        .font(.footnote.weight(on ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(on ? Theme.onAccent : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: DS.hit)
                        .background(on ? Theme.accent : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint(on ? "Tap again for the \(on && view.deep ? "base" : "deeper") view" : "")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .sunPanel(Capsule(), thin: true)
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map layer")
    }
}

/// F-33: the legend under the row: the view's title, its colour bar and the two ends (and the wind-cost line when there is one).
struct LayerLegend: View {
    let scale: LayerScale
    /// When the view has nothing to draw (no readings, no wind yet)
    var emptyText: String?
    @Environment(\.sunlight) private var sunlight

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(scale.title).font(.caption.weight(.semibold))
            if let emptyText {
                Text(emptyText).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                LinearGradient(colors: (0...12).map { i in
                    GradientPath.color(scale.ramp, scale.ramp.lo + (scale.ramp.hi - scale.ramp.lo) * Double(i) / 12)
                }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 8)
                .clipShape(Capsule())
                HStack {
                    Text(scale.low)
                    Spacer(minLength: 4)
                    Text(scale.high)
                }
                .font(.caption2.weight(sunlight ? .bold : .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                if let note = scale.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(width: 170, alignment: .leading)
        .padding(8)
        .glassCard(radius: 12, padding: 0, thin: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(emptyText.map { "\(scale.title). \($0)" } ?? "\(scale.title), colour scale \(scale.low) to \(scale.high)")
    }
}

/// F-33: a stop as a dot, sized by how long it lasted
struct StopDotMark: View {
    let stop: StopDot

    var body: some View {
        let size = 10 + min(14, stop.durationS / 60 * 3)
        Circle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 2))
            .accessibilityLabel(stop.text)
    }
}
