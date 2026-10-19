import Observation
import SwiftUI

/// A3 (F-19): a true circular reveal. Start presses in (0.16 s), then a circle grows from the Start disc centre (0.5 s) and the live ride
/// screen appears through it; the cover does not slide up. The Kick-off sound (`ride_start`, T = 0.66 s) starts in the same frame as the
/// growth. Reduce Motion: no growth, the cover just fades in as before. Nothing here is decorative: it only plays when the rider presses Start.
@Observable
final class StartTransition {
    static let shared = StartTransition()

    static let pressS = 0.16
    static let growS = 0.5

    /// true from the press until a moment after the growth: the cover is shown without its slide-up meanwhile
    private(set) var visible = false
    /// the orange edge is on screen (from a frame before the growth)
    private(set) var growing = false
    /// the circle has reached the far corner (animated, so it is 0 while pressing and 1 after the growth)
    private(set) var grown = false
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
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            grown = false
            growing = false
            visible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressS - 0.02) {
            guard g == self.generation else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.growing = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressS) {
            guard g == self.generation else { return }
            withAnimation(.easeInOut(duration: Self.growS)) { self.grown = true }
        }
        // the cover opens a moment after the engine starts the ride; once it has had time to, the reveal is over
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressS + Self.growS + 1.2) {
            guard g == self.generation else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.visible = false; self.growing = false }
        }
    }
}

/// A circle around `center` (in the shape's own coordinates). `progress` 0 is `startRadius`, 1 reaches the farthest corner of the rect.
private struct RevealCircle: Shape {
    var center: CGPoint
    var startRadius: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let far = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
        let r = startRadius + (far + 2 - startRadius) * progress
        return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }
}

/// Inactive: a rectangle far bigger than the screen, so nothing is cut (the map runs under the safe areas).
private struct RevealClip: Shape {
    var active: Bool
    var circle: RevealCircle

    var animatableData: CGFloat {
        get { circle.progress }
        set { circle.progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        active ? circle.path(in: rect) : Path(rect.insetBy(dx: -2_000, dy: -2_000))
    }
}

private struct StartReveal: ViewModifier {
    private let t = StartTransition.shared
    @State private var origin = CGPoint.zero

    func body(content: Content) -> some View {
        let local = CGPoint(x: t.center.x - origin.x, y: t.center.y - origin.y)
        let p: CGFloat = t.grown ? 1 : 0
        content
            .clipShape(RevealClip(active: t.visible, circle: RevealCircle(center: local, startRadius: 0, progress: p)))
            .overlay {
                // the orange edge of the circle: it starts as the disc and thins out to nothing as it spreads
                if t.visible {
                    RevealCircle(center: local, startRadius: t.diameter / 2 * 0.97, progress: p)
                        .fill(Theme.accent)
                        .opacity(t.growing ? (t.grown ? 0 : 1) : 0)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .global).origin }) { origin = $0 }
    }
}

extension View {
    /// A3: the live ride screen appears through a circle growing from the Start disc (a no-op when nothing is playing).
    func startReveal() -> some View { modifier(StartReveal()) }
}
