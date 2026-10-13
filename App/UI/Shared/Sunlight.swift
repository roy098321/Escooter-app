import CorckieCore
import Observation
import SwiftUI
import UIKit

/// M6-03 (C30): the sunlight style, applied to the whole app.
/// - Settings → Sunlight mode: Auto (screen brightness >= 90% in daylight hours, or iOS Increase Contrast / Reduce Transparency),
///   On, Off. The rule is `SunlightRule` (Core, unit tested).
/// - On = solid panels with a black edge instead of glass, bold text, light colours, a thicker path on the live map.
/// - Read at foreground, when the setting changes and every 30 s (the brightness slider moves in the pocket, in the sun).
@MainActor
@Observable
final class SunlightMonitor {
    static let shared = SunlightMonitor()
    private(set) var active = false
    private init() {}

    /// ui-shots (`-uiShot sun-...`) force the style on
    var on: Bool { UIShot.sunlight || active }

    func refresh() {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let hour = Calendar.current.component(.hour, from: Date())
        let setting = DisplaySettings.sunlight(AppModel.shared.displayDatabase).rawValue
        let now = SunlightRule.active(setting: setting, brightness: screen.map { Double($0.brightness) }, hour: hour,
                                      increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled,
                                      reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
        if now != active { active = now }
    }
}

private struct SunlightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The sunlight style is on (set once at the root by `sunlightRoot()`)
    var sunlight: Bool {
        get { self[SunlightKey.self] }
        set { self[SunlightKey.self] = newValue }
    }
}

private struct SunlightRoot: ViewModifier {
    @Environment(\.scenePhase) private var phase
    private let monitor = SunlightMonitor.shared
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .environment(\.sunlight, monitor.on)
            .environment(\.legibilityWeight, monitor.on ? LegibilityWeight.bold : nil)
            .scrollBounceBehavior(.basedOnSize)   // B17: screens that fit do not rubber-band
            .preferredColorScheme(monitor.on ? .light : nil)
            .onAppear { monitor.refresh() }
            .onChange(of: phase) { _, p in if p == .active { monitor.refresh() } }
            .onReceive(ticker) { _ in monitor.refresh() }
    }
}

/// A solid panel (hairline system separator, no black outline) in sunlight, the system material otherwise.
/// `edge` draws the thin white glass edge inside the background, so content (the Home disc) stays in front of it.
struct SunPanel<S: InsettableShape>: ViewModifier {
    @Environment(\.sunlight) private var sunlight
    let shape: S
    var thin = false
    var edge = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if sunlight {
                        shape.fill(Color(.systemBackground))
                        shape.strokeBorder(Color(.separator), lineWidth: 0.5)
                    } else {
                        if thin {
                            shape.fill(.thinMaterial)
                        } else {
                            shape.fill(.ultraThinMaterial)
                        }
                        if edge { shape.strokeBorder(.white.opacity(0.35), lineWidth: 1) }
                    }
                }
            }
    }
}

extension View {
    /// Applies the sunlight style to the whole app (once, at the root).
    func sunlightRoot() -> some View { modifier(SunlightRoot()) }

    func sunPanel<S: InsettableShape>(_ shape: S, thin: Bool = false, edge: Bool = false) -> some View {
        modifier(SunPanel(shape: shape, thin: thin, edge: edge))
    }
}

extension Color {
    /// "#RRGGBB" (the speed palettes of Core); grey when it cannot be read
    init(hex: String) {
        if let c = SpeedPalette.rgb(hex) {
            self.init(red: c.r, green: c.g, blue: c.b)
        } else {
            self = .gray
        }
    }
}
