import SwiftUI

/// The glass tile of the live ride view (CONCEPT "Look and feel"): a translucent material with a thin edge, so the
/// map stays visible behind the numbers. On iOS 26 the system "liquid glass" can replace the material later (the
/// build SDK of CI does not have it yet); until then every iOS version gets the material.
/// M6-03 (C30): in the sunlight style the glass turns into a solid panel with a black edge (`SunPanel`).
struct GlassCard<Content: View>: View {
    var tint: Color?
    private let content: Content
    @Environment(\.sunlight) private var sunlight

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                if let tint { shape.fill(tint.opacity(sunlight ? 0.5 : 0.35)) }
            }
            .sunPanel(shape)
            .overlay {
                if !sunlight { shape.strokeBorder(.white.opacity(0.25), lineWidth: 1) }
            }
    }
}
