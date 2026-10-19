import SwiftUI
import ObjectiveC
import UIKit

/// B20 / B23 (owner, 13 Oct): "not a wall, a slight elasticity, stiffer than stock iOS". iOS has no stiffness setting, so this
/// one shared helper finds the UIScrollView behind a SwiftUI `ScrollView` / `List` and remaps its overscroll: the stock rubber band
/// is damped by `resistance` and capped at about `capPt`, and the spring back therefore also covers only that short distance.
/// Tune the feel here, nowhere else. Fallback if it ever misbehaves: set `enabled` to false (stock bounce, nothing else changes;
/// the tab bar then simply stays, because this hook is also what reports list scrolling to `TabBarVisibility`, F-14).
enum StiffBounce {
    /// the most a scroll view may be pulled past its end, in points (owner: about 30 to 40)
    static let capPt: CGFloat = 35
    /// how much of the stock overscroll gets through at first (stock = 1, lower = stiffer)
    static let resistance: CGFloat = 0.35
    static let enabled = true

    /// stock overscroll in, stiff overscroll out: starts at `resistance` times the pull and flattens out at `capPt`
    static func damped(_ overscroll: CGFloat) -> CGFloat {
        guard overscroll > 0 else { return 0 }
        return capPt * CGFloat(tanh(Double(overscroll * resistance / capPt)))
    }

    /// The content offset to use for a stock offset `y` (pure maths; see the unit test)
    static func clamped(y: CGFloat, top: CGFloat, bottom: CGFloat) -> CGFloat {
        if y < top { return top - damped(top - y) }
        if bottom >= top, y > bottom { return bottom + damped(y - bottom) }
        return y
    }
}

extension View {
    /// The shared short, stiff bounce: apply to a `ScrollView` or `List` (or its content).
    func stiffBounce() -> some View {
        background { if StiffBounce.enabled { StiffBounceInstaller().frame(width: 0, height: 0).accessibilityHidden(true) } }
    }

    /// B20 / B23: room under the content for the floating tab bar, so the last item scrolls fully above it (F-14: no raised disc)
    func tabBarClearance() -> some View {
        contentMargins(.bottom, FloatingTabBar.clearance, for: .scrollContent)
    }
}

private struct StiffBounceInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Finder {
        let v = Finder()
        v.isUserInteractionEnabled = false
        v.onWindow = { [weak coordinator = context.coordinator] view in coordinator?.attach(from: view) }
        return v
    }

    func updateUIView(_ uiView: Finder, context: Context) {}

    final class Finder: UIView {
        var onWindow: ((UIView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onWindow?(self) }
        }
    }

    final class Coordinator {
        private var observation: NSKeyValueObservation?
        private weak var scrollView: UIScrollView?
        private var busy = false

        deinit {
            if let s = scrollView { objc_setAssociatedObject(s, Self.hookedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        }
        private static let hookedKey = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)

        func attach(from view: UIView, retries: Int = 3) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                if let found = Self.scrollView(near: view) {
                    self.hook(found)
                } else if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.attach(from: view, retries: retries - 1) }
                }
            }
        }

        /// A `ScrollView` puts this view inside its UIScrollView; for a `List` the UIScrollView is a sibling of the background.
        private static func scrollView(near view: UIView) -> UIScrollView? {
            var node: UIView? = view
            var levels = 0
            while let n = node, levels < 8 {
                if let s = n as? UIScrollView { return s }
                if let s = firstScrollView(in: n, skipping: view) { return s }
                node = n.superview
                levels += 1
            }
            return nil
        }

        private static func firstScrollView(in root: UIView, skipping: UIView) -> UIScrollView? {
            for sub in root.subviews where sub !== skipping {
                if let s = sub as? UIScrollView { return s }
                if let s = firstScrollView(in: sub, skipping: skipping) { return s }
            }
            return nil
        }

        private func hook(_ s: UIScrollView) {
            guard scrollView !== s, objc_getAssociatedObject(s, Self.hookedKey) == nil else { return }
            objc_setAssociatedObject(s, Self.hookedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)   // one hook per scroll view, or the damping would compound
            scrollView = s
            s.bounces = true
            observation = s.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                self?.remap(sv)
                Self.report(sv)
            }
        }

        /// F-14: list scrolling moves the floating tab bar (only scrolling the finger or its momentum drives, not layout changes)
        private static func report(_ s: UIScrollView) {
            guard s.isTracking || s.isDecelerating else { return }
            let inset = s.adjustedContentInset
            let y = s.contentOffset.y
            let top = -inset.top
            let bottom = s.contentSize.height - s.bounds.height + inset.bottom
            MainActor.assumeIsolated { TabBarVisibility.shared.scrolled(y: y, top: top, bottom: bottom) }
        }

        private func remap(_ s: UIScrollView) {
            guard !busy else { return }
            let inset = s.adjustedContentInset
            let top = -inset.top
            let bottom = s.contentSize.height - s.bounds.height + inset.bottom
            let y = s.contentOffset.y
            let target = StiffBounce.clamped(y: y, top: top, bottom: bottom)
            guard abs(target - y) > 0.01 else { return }
            busy = true
            s.contentOffset.y = target
            busy = false
        }
    }
}
