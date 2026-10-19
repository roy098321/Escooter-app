import Observation
import SwiftUI

/// A3 (F-19): Start presses in (0.16 s), then grows from its centre until it fills the screen (0.5 s), which is the live view's entrance.
/// The Kick-off sound (`ride_start`, T = 0.66 s) starts in the same frame and is silent by the end of the growth. Reduce Motion: no growth,
/// the live view just fades in (T = 0.2 s). Nothing here is decorative: it only plays when the rider presses Start.
@Observable
final class StartTransition {
    static let shared = StartTransition()

    static let pressS = 0.16
    static let growS = 0.5

    private(set) var visible = false
    private(set) var grown = false
    private(set) var pressed = false
    private(set) var fading = false
    private(set) var center = CGPoint.zero
    private(set) var diameter: CGFloat = 250
    @ObservationIgnored private var generation = 0

    private init() {}

    func begin(center: CGPoint, diameter: CGFloat, reduceMotion: Bool) {
        guard !reduceMotion, diameter > 10 else { return }
        generation += 1
        let g = generation
        self.center = center
        self.diameter = diameter
        grown = false
        pressed = false
        fading = false
        visible = true
        withAnimation(.easeIn(duration: Self.pressS)) { pressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressS) {
            guard g == self.generation else { return }
            withAnimation(.easeInOut(duration: Self.growS)) { self.grown = true }
        }
        // the live view takes over (the cover opens a moment after the engine starts the ride), then the colour fades away
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressS + Self.growS + 0.9) {
            guard g == self.generation else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.fading = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressS + Self.growS + 1.2) {
            guard g == self.generation else { return }
            self.visible = false
        }
    }
}

struct StartTransitionOverlay: View {
    private let t = StartTransition.shared

    var body: some View {
        GeometryReader { geo in
            if t.visible {
                let reach = max(geo.size.width, geo.size.height) * 2.4 / max(t.diameter, 1)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: t.diameter, height: t.diameter)
                    .scaleEffect(t.grown ? reach : (t.pressed ? 0.94 : 1))
                    .opacity(t.fading ? 0 : 1)
                    .position(x: t.center.x - geo.frame(in: .global).minX, y: t.center.y - geo.frame(in: .global).minY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
