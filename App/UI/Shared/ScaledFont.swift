import SwiftUI

/// M6-04: a rounded number font that follows Dynamic Type (the live view's numbers stay fixed on purpose: >= 76 / 60 pt).
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let mono: Bool

    init(size: CGFloat, weight: Font.Weight, mono: Bool, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.mono = mono
    }

    func body(content: Content) -> some View {
        let font = Font.system(size: size, weight: weight, design: .rounded)
        return content.font(mono ? font.monospacedDigit() : font)
    }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, mono: Bool = false, relativeTo style: Font.TextStyle = .title3) -> some View {
        modifier(ScaledFont(size: size, weight: weight, mono: mono, style: style))
    }
}
