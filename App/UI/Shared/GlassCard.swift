import SwiftUI

/// The glass tile of the live ride view (CONCEPT "Look and feel"): a translucent material with a thin edge, so the
/// map stays visible behind the numbers. On iOS 26 the system "liquid glass" can replace the material later (the
/// build SDK of CI does not have it yet); until then every iOS version gets the material.
struct GlassCard<Content: View>: View {
    var tint: Color?
    private let content: Content

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial)
                    if let tint {
                        RoundedRectangle(cornerRadius: 28, style: .continuous).fill(tint.opacity(0.35))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
    }
}
