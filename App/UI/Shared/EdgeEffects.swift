import SwiftUI

// N6-3 / N6-4 (batch 6, "minimal interactions", owner 15 Nov): soft edges instead of hard cuts.
// N6-4 progressive blur: a material that fades in towards the edge (behind the floating tab bar and the map top bars), so a busy map
// or list never fights the controls. On iOS 26 Liquid Glass (N7-2) takes over; this stays the iOS 17-25 look.
// Sunlight mode: nothing (solid panels read best outside). Reduce Transparency: a plain background fade instead of the blur.
// N6-3 scroll fade: content fades out at an edge (above the tab bar, under the top of a map screen's scroll sheet).

struct ProgressiveBlur: View {
    enum Edge { case top, bottom }
    var edge: Edge
    @Environment(\.sunlight) private var sunlight
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if sunlight {
            Color.clear
        } else {
            Group {
                if reduceTransparency {
                    Rectangle().fill(Theme.background)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.7), location: 0.55),
                                       .init(color: .black, location: 1)],
                               startPoint: edge == .bottom ? .top : .bottom, endPoint: edge == .bottom ? .bottom : .top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// N6-3: content fades out over `top` / `bottom` points at those edges (0 = a hard edge, as before)
    func scrollFadeEdges(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
            }
            .ignoresSafeArea()
        }
    }
}
