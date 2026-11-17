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

// Xcode 26 builds opt the whole app into the iOS 26 look: toolbar buttons get a shared glass shell and scroll views get a soft
// "edge effect" under the bars. The app draws its own round buttons and bars, so both are switched off (owner, 18 Nov: grey bands
// at the top and bottom, odd shapes around the gear and the logo).
extension ToolbarContent {
    /// iOS 26: no shared glass shell behind this toolbar item (its own round button stays)
    @ToolbarContentBuilder func noSystemGlass() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension View {
    /// iOS 26: no automatic edge effect (grey band) where scroll content meets the bars
    @ViewBuilder func noSystemEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

