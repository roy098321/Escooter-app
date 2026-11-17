import SwiftUI

// N7-2 (batch 7): Liquid Glass on iOS 26 for the controls that float over maps: the floating tab bar, the map top bars and round
// buttons, the map layer control, the map screens' sheet and the Live screen tiles. Plain-page cards (Stats, Settings) keep their
// look. The selected tab keeps its SOLID orange pill (readable in the sun). Sunlight mode wins (solid panels, no glass) and
// Reduce Transparency keeps today's look. iOS 17-25: today's material, with the N6-4 progressive blur behind the tab bar.

extension View {
    /// The iOS 26 glass in `shape` when `enabled`, else `otherwise` (today's look).
    @ViewBuilder func liquidGlass<S: Shape, V: View>(in shape: S, interactive: Bool = false, tint: Color? = nil, enabled: Bool,
                                                     @ViewBuilder otherwise: (Self) -> V) -> some View {
        if #available(iOS 26.0, *), enabled {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            otherwise(self)
        }
    }
}

enum LiquidGlass {
    /// Glass is used: iOS 26, not in sunlight mode, Reduce Transparency off
    static func allowed(sunlight: Bool, reduceTransparency: Bool) -> Bool {
        guard !sunlight, !reduceTransparency else { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }
}
