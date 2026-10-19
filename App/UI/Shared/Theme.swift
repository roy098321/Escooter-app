import SwiftUI
import UIKit

/// F-15 theme v2 "Desert dusk" (owner, 18 Oct; mock-up theme-desert-dusk-v2): the one place the app's colours are defined.
/// Every screen draws with these tokens, never with system blue or the old frosted grey. Each token has a light and a dark value
/// (resolved by iOS from the trait collection, so dark mode, sunlight mode and the ui-shots' `dark-` prefix all follow).
///
/// Rules (owner answers + contrast check):
/// - The main colour is WHITE (light) / neutral #121212 (dark). Cards are a faint sand tint, chips a stronger sand.
/// - `accent` (#F89355) is for fills, icons, the selected tab, the main button and large numbers. Orange text on white is only
///   2.3:1, so orange TEXT (links, small values) uses `accentInk` (#B85A1E in light = 4.6:1, the same orange in dark = 8:1), and
///   text ON an orange fill uses `onAccent` (dark), never white.
/// - Browns only for small labels: `sectionLabel` (rust #965530 in light = 5.8:1, canyon #C37F51 in dark), `muted` sparingly.
/// - `danger` / `ok` keep their meaning (errors, delete, the hot motor / connected, done) and stay distinct from the orange.
/// - Speed colours on maps are not here: they come from Core `SpeedPalette` (colour-blind mode keeps its own set).
enum Theme {
    // MARK: Surfaces

    /// page background: white / neutral dark
    static let background = dynamic(light: 0xFFFFFF, dark: 0x121212)
    /// cards and tiles on a page: faint sand / dark grey
    static let card = dynamic(light: 0xF8F3EB, dark: 0x1F1F1F)
    /// chips, segmented-control tracks, small pills: stronger sand / a step lighter than cards
    static let chip = dynamic(light: 0xF3E7D3, dark: 0x262626)
    /// the page behind Apple-style grouped lists (owner: very light warm white, not #F2F2F7)
    static let groupedBackground = dynamic(light: 0xF7F3ED, dark: 0x121212)
    /// the rows of grouped lists
    static let row = dynamic(light: 0xFFFFFF, dark: 0x1F1F1F)
    /// hairlines on cards and the tab bar
    static let line = dynamic(light: 0xEADFCF, dark: 0x2E2E2E)
    /// the floating tab bar and docked sheets
    static let bar = dynamic(light: 0xFFFFFF, dark: 0x1F1F1F)

    // MARK: Accent

    /// brand orange for fills, icons, the selected tab, the main button and large numbers (also the app's AccentColor asset)
    static let accent = dynamic(light: 0xF89355, dark: 0xF89355)
    /// a softer orange (selected pill behind a filled icon, chart bars)
    static let accentSoft = dynamic(light: 0xF7A462, dark: 0xF7A462)
    /// orange that is readable as small text (links, inline values); the app tint
    static let accentInk = dynamic(light: 0xB85A1E, dark: 0xF89355)
    /// text and icons on an orange fill
    static let onAccent = dynamic(light: 0x24160C, dark: 0x1A1410)

    // MARK: Text

    /// small section labels (uppercase): rust in light, canyon in dark
    static let sectionLabel = dynamic(light: 0x965530, dark: 0xC37F51)
    /// canyon, the secondary brown (small labels on cards, chart axes)
    static let canyon = dynamic(light: 0xC37F51, dark: 0xC37F51)
    /// earth: muted text at low emphasis, use sparingly (the system secondary stays the default)
    static let muted = dynamic(light: 0x64422C, dark: 0xB3A497)

    // MARK: Meaning

    /// danger, errors, delete
    static let danger = dynamic(light: 0xE5484D, dark: 0xE5484D)
    /// connected, OK, done
    static let ok = dynamic(light: 0x3FA45B, dark: 0x3FA45B)

    /// Every token by name, for the theme check (u61) and the readability page.
    static let all: [(name: String, light: UInt32, dark: UInt32)] = [
        ("background", 0xFFFFFF, 0x121212), ("card", 0xF8F3EB, 0x1F1F1F), ("chip", 0xF3E7D3, 0x262626),
        ("groupedBackground", 0xF7F3ED, 0x121212), ("row", 0xFFFFFF, 0x1F1F1F), ("line", 0xEADFCF, 0x2E2E2E), ("bar", 0xFFFFFF, 0x1F1F1F),
        ("accent", 0xF89355, 0xF89355), ("accentSoft", 0xF7A462, 0xF7A462), ("accentInk", 0xB85A1E, 0xF89355), ("onAccent", 0x24160C, 0x1A1410),
        ("sectionLabel", 0x965530, 0xC37F51), ("canyon", 0xC37F51, 0xC37F51), ("muted", 0x64422C, 0xB3A497),
        ("danger", 0xE5484D, 0xE5484D), ("ok", 0x3FA45B, 0x3FA45B)
    ]

    // MARK: Helpers

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light) })
    }

    static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// WCAG contrast ratio of two sRGB colours (1 to 21); used by the theme check
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            func ch(_ v: UInt32) -> Double {
                let s = Double(v & 0xFF) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch(c >> 16) + 0.7152 * ch(c >> 8) + 0.0722 * ch(c)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// SF Pro Rounded for the navigation titles (owner: numbers and titles rounded, body text stays the default font).
    @MainActor static func applyRoundedTitles() {
        func rounded(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style)
            let bold = UIFont.systemFont(ofSize: base.pointSize, weight: weight)
            guard let d = bold.fontDescriptor.withDesign(.rounded) else { return bold }
            return UIFont(descriptor: d, size: base.pointSize)
        }
        let bar = UINavigationBar.appearance()
        bar.titleTextAttributes = [.font: rounded(.headline, .semibold)]
        bar.largeTitleTextAttributes = [.font: rounded(.largeTitle, .bold)]
    }
}

private struct ThemeRoot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Theme.accentInk)
    }
}

extension View {
    /// Theme v2 for the whole app (once, at the root): orange tint instead of the iOS blue. (The rounded navigation titles are
    /// set by `RootView.init` through `Theme.applyRoundedTitles()`, before the first bar is made.)
    func themeRoot() -> some View { modifier(ThemeRoot()) }
}
