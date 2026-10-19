import CorckieCore
import SwiftUI
import UIKit

/// P6-2 chunk 1 checks (the redesign foundation), on made-up input, no screen needed: u61 theme v2 colours and contrast (F-15),
/// u62 the flat tab bar's hide-on-scroll rule and layout (F-14; since P6-3 a screen with a bottom action holds it away instead of a sheet
/// pinning it). The docked map sheets (u63, B19) are gone with B29; the P6-3 checks are in P63Checks.swift.
@MainActor
enum P62Checks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " · ") }
    }

    static func run() {
        runTheme()
        runTabBar()
        runDeclutter()
        runRides()
        runStats()
    }

    // MARK: u64

    private static func runDeclutter() {
        let expect = Expect()
        let words = [HomePrimary.connect, .startRide, .tryAgain, .openRide].map { HomeCopy.buttonWord($0, connecting: false) }
        expect(words == ["Connect", "Start", "Try again", "Live view"] && !words.contains { $0.lowercased().contains("scooter") }, "the big button is one short word")
        let now = Date().timeIntervalSince1970
        let ready = HomeLogic.model(HomeInput(paired: true, connected: true, nowS: now, batteryPct: 91))
        let away = HomeLogic.model(HomeInput(paired: true, connected: false, nowS: now, lastSeenMs: Int64((now - 600) * 1000), lastSeenPct: 58))
        let readyText = HomeCopy.statusText(ready), awayText = HomeCopy.statusText(away)
        expect(readyText == "Connected" && ready.batteryText == "91%", "ready pill: Connected + battery")
        expect(awayText.hasPrefix("Not connected \u{00B7} seen ") && !awayText.contains("last"), "away pill: Not connected, seen time")
        let strip = ArrivalStrip.shortText(arrivalS: 1_000_300, nowS: 1_000_000, utcOffsetMin: 0)
        expect(strip.hasSuffix("5 min") && !strip.contains("left") && !strip.contains("arrive"), "arrival strip: time and minutes only")
        CheckResults.shared.set("u64", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u61

    /// the colour a token really resolves to in light or dark mode, as 0xRRGGBB
    private static func resolved(_ c: Color, dark: Bool) -> UInt32 {
        let ui = UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private static func runTheme() {
        let expect = Expect()
        let tokens: [(String, Color)] = [("background", Theme.background), ("card", Theme.card), ("chip", Theme.chip), ("accent", Theme.accent),
                                         ("accentInk", Theme.accentInk), ("sectionLabel", Theme.sectionLabel), ("danger", Theme.danger), ("ok", Theme.ok)]
        let table = Dictionary(uniqueKeysWithValues: Theme.all.map { ($0.name, ($0.light, $0.dark)) })
        let wrong = tokens.filter { name, colour in
            guard let want = table[name] else { return true }
            return resolved(colour, dark: false) != want.0 || resolved(colour, dark: true) != want.1
        }
        expect(wrong.isEmpty, wrong.isEmpty ? "8 tokens resolve to their light and dark values" : "tokens off: \(wrong.map(\.0).joined(separator: ", "))")
        expect(table["background"]?.0 == 0xFFFFFF && table["background"]?.1 == 0x121212 && table["card"]?.0 == 0xF8F3EB && table["accent"]?.0 == 0xF89355,
               "white / #121212 page, #F8F3EB cards, #F89355 accent")
        let ink = Theme.contrast(0xB85A1E, 0xFFFFFF)
        expect(ink >= 4.5, String(format: "small orange text %.1f:1 on white (min 4.5; the bright orange is %.1f:1, fills only)", ink, Theme.contrast(0xF89355, 0xFFFFFF)))
        let label = Theme.contrast(0x965530, 0xFFFFFF), labelDark = Theme.contrast(0xC37F51, 0x121212), muted = Theme.contrast(0x64422C, 0xFFFFFF)
        expect(label >= 4.5 && labelDark >= 4.5 && muted >= 4.5, String(format: "section labels %.1f:1 / %.1f:1 dark, muted %.1f:1", label, labelDark, muted))
        let onAccent = Theme.contrast(0x24160C, 0xF89355)
        expect(onAccent >= 4.5, String(format: "dark text on the orange %.1f:1", onAccent))
        expect(resolved(Theme.danger, dark: false) != resolved(Theme.accent, dark: false) && resolved(Theme.ok, dark: false) != resolved(Theme.accent, dark: false),
               "danger red and OK green stay apart from the orange")
        CheckResults.shared.set("u61", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u62

    private static func runTabBar() {
        let expect = Expect()
        var rule = TabBarHideRule()
        // a list 2000 pt tall in a 700 pt window: top 0, bottom 1300
        _ = rule.step(y: 0, top: 0, bottom: 1300)
        _ = rule.step(y: 60, top: 0, bottom: 1300)
        let hidden = rule.step(y: 90, top: 0, bottom: 1300)
        expect(hidden, "30 pt down past the top hides the bar")
        _ = rule.step(y: 400, top: 0, bottom: 1300)
        let shown = !rule.step(y: 385, top: 0, bottom: 1300)
        expect(shown, "15 pt back up shows it again")
        var top = TabBarHideRule()
        _ = top.step(y: 0, top: 0, bottom: 1300)
        expect(!top.step(y: 35, top: 0, bottom: 1300), "the first 40 pt never hide it")
        var bounce = TabBarHideRule()
        _ = bounce.step(y: 1200, top: 0, bottom: 1300)
        _ = bounce.step(y: 1300, top: 0, bottom: 1300)
        let before = bounce.hidden
        _ = bounce.step(y: 1335, top: 0, bottom: 1300)
        _ = bounce.step(y: 1300, top: 0, bottom: 1300)
        expect(bounce.hidden == before, "the bounce past the end changes nothing")
        let v = TabBarVisibility.shared
        v.show()
        v.scrolled(y: 0, top: 0, bottom: 1300)
        v.scrolled(y: 200, top: 0, bottom: 1300)
        v.scrolled(y: 400, top: 0, bottom: 1300)
        let scrolledAway = v.hidden
        v.show()
        v.hold()
        let held = v.hidden
        v.scrolled(y: 0, top: 0, bottom: 1300)
        let stillHeld = v.hidden
        v.release()
        let given = !v.hidden
        v.show()
        expect(scrolledAway, "scrolling down hides the bar")
        expect(held && stillHeld && given, "a screen with a bottom action (Add a place) holds the bar away and gives it back (B28)")
        let items = FloatingTabBar.items
        expect(items.count == 5 && items[2].title == "Home", "five icons, Home in the middle")
        expect(FloatingTabBar.clearance >= FloatingTabBar.barHeight + FloatingTabBar.bottomGap, "the bottom margin covers the bar (\(Int(FloatingTabBar.clearance)) pt)")
        CheckResults.shared.set("u62", expect.ok ? .pass : .fail, expect.line)
    }
}
