import SwiftUI

/// The glass tile of the live ride view (CONCEPT "Look and feel"): a translucent material with a thin edge, so the
/// map stays visible behind the numbers. On iOS 26 the system "liquid glass" can replace the material later (the
/// N7-0: CI now builds with the iOS 26 SDK (Xcode 26); N7-2 adds the glass behind #available(iOS 26).
/// M6-03 (C30): in the sunlight style the glass turns into a solid panel with a black edge (`SunPanel`).
struct GlassCard<Content: View>: View {
    var tint: Color?
    private let content: Content
    @Environment(\.sunlight) private var sunlight
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // N7-2: the Live tiles are Liquid Glass on iOS 26 (a tint stays a tint); sunlight = solid panel
            .liquidGlass(in: shape, tint: tint?.opacity(0.35),
                         enabled: LiquidGlass.allowed(sunlight: sunlight, reduceTransparency: reduceTransparency)) { tile in
                tile
                    .background {
                        if let tint { shape.fill(tint.opacity(sunlight ? 0.5 : 0.35)) }
                    }
                    .sunPanel(shape)
                    .overlay {
                        if !sunlight { shape.strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    }
            }
    }
}
