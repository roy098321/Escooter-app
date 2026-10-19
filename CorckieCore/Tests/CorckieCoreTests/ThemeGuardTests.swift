import XCTest

/// P6-2 chunk 1 (F-15 theme v2, F-14 flat tab bar, B19 docked sheets, G3 / G12), checked against the app's source text on Linux CI
/// like the live-view and version-label guards: no iOS blue left in the UI code, every screen draws with the `Theme` tokens, and
/// the foundation the next chunks build on stays in place.
final class ThemeGuardTests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    private func uiFiles() throws -> [(name: String, source: String)] {
        guard let walker = FileManager.default.enumerator(at: appFolder.appendingPathComponent("UI"), includingPropertiesForKeys: nil) else {
            XCTFail("App/UI not found")
            return []
        }
        var out: [(String, String)] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            out.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 40)
        return out
    }

    /// F-15: the orange replaces the iOS blue everywhere; `Color.accentColor` is not used directly (the tokens say which orange)
    func test_F15_noSystemBlueLeftInTheUI() throws {
        let banned = [".blue)", ".blue,", ".blue ", ".blue]", "Color.blue", "systemBlue", ".tint(.blue)", "Color.accentColor", ".accentColor", ".indigo", ".teal", ".cyan"]
        for (name, source) in try uiFiles() {
            for b in banned where source.contains(b) {
                XCTFail("\(name) uses \(b): use a Theme token (Theme.accent / accentInk / …) instead")
            }
        }
    }

    func test_F15_tokensHaveTheApprovedValues() throws {
        let theme = try text("UI/Shared/Theme.swift")
        for line in ["background = dynamic(light: 0xFFFFFF, dark: 0x121212)", "card = dynamic(light: 0xF8F3EB, dark: 0x1F1F1F)",
                     "chip = dynamic(light: 0xF3E7D3, dark: 0x262626)", "accent = dynamic(light: 0xF89355, dark: 0xF89355)",
                     "canyon = dynamic(light: 0xC37F51, dark: 0xC37F51)", "muted = dynamic(light: 0x64422C",
                     "danger = dynamic(light: 0xE5484D, dark: 0xE5484D)", "ok = dynamic(light: 0x3FA45B, dark: 0x3FA45B)"] {
            XCTAssertTrue(theme.contains(line), "Theme.swift: \(line)")
        }
        XCTAssertTrue(try text("UI/RootView.swift").contains(".themeRoot()"), "the orange tint is set at the root")
        XCTAssertTrue(theme.contains(".tint(Theme.accentInk)"))
        let asset = try text("Resources/Assets.xcassets/AccentColor.colorset/Contents.json")
        XCTAssertTrue(asset.contains("\"red\" : \"0xF8\"") && asset.contains("\"green\" : \"0x93\"") && asset.contains("\"blue\" : \"0x55\""))
        let yml = try String(contentsOf: appFolder.deletingLastPathComponent().appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor"))
    }

    /// owner answer 1: the list screens keep Apple's grouped layout in the theme colours, not the grey frosted glass
    func test_F15_listsAndCardsUseTheTokens() throws {
        let ds = try text("UI/Shared/DesignSystem.swift")
        XCTAssertTrue(ds.contains("Theme.groupedBackground") && ds.contains("Theme.row"), "grouped lists in theme colours")
        XCTAssertFalse(ds.contains("systemGroupedBackground"), "no grey #F2F2F7 page")
        XCTAssertTrue(ds.contains("shape.fill(sunlight ? Theme.row : Theme.card)"), "cards are sand, white in sunlight")
        // owner answer 2: only Home has a (muted) map behind it
        let backdrop = try text("UI/Shared/MapBackdrop.swift")
        XCTAssertTrue(backdrop.contains("if sunlight || !map") && backdrop.contains(".saturation("))
        XCTAssertTrue(try text("UI/Home/HomeView.swift").contains("MapBackdrop(map: true)"))
        // the live screen stays dark (except sunlight mode)
        let root = try text("UI/RootView.swift")
        XCTAssertTrue(root.contains("LiveRideView().liveDark()"))
    }

    /// F-14: one flat capsule, icons only, Home a normal icon, the selected tab a filled icon on an orange pill, hides on scroll
    func test_F14_flatTabBar() throws {
        let bar = try text("UI/Shared/FloatingTabBar.swift")
        XCTAssertFalse(bar.contains("Text(item.title)"), "icons only (VoiceOver keeps the names)")
        XCTAssertTrue(bar.contains(".accessibilityLabel(item.title)"))
        XCTAssertFalse(bar.contains("discSize") || bar.contains("item.id == 2"), "no raised Home disc")
        XCTAssertTrue(bar.contains(".symbolVariant(on ? .fill : .none)") && bar.contains("Capsule().fill(Theme.accent)"))
        XCTAssertTrue(bar.contains("accessibilityReduceMotion"), "the slide honours Reduce Motion")
        XCTAssertTrue(try text("UI/Shared/StiffBounce.swift").contains("TabBarVisibility.shared.scrolled("), "list scrolling drives the bar")
        XCTAssertTrue(try text("UI/RootView.swift").contains(".floatingTabBar(selection: $tab"))
    }

    /// B19: the map sheets dock on the bar; the task sheets stay standard iOS sheets
    func test_B19_mapSheetsDockOnTheBar() throws {
        let sheet = try text("UI/Shared/MapSheet.swift")
        XCTAssertTrue(sheet.contains("TabBarVisibility.shared.pin()"), "a map sheet pins the bar")
        XCTAssertTrue(sheet.contains(".padding(.bottom, d.barSpace)") && sheet.contains("d.contentHeight(at: current)"), "content cut at the bar's top")
        for file in ["UI/Rides/RideDetailView.swift", "UI/Routes/RouteCardView.swift", "UI/Routes/PlaceMapView.swift"] {
            XCTAssertTrue(try text(file).contains("MapSheet(initial:") && text(file).contains("summary:"), "\(file) docks its sheet with a summary line")
        }
        let home = try text("UI/Home/HomeView.swift")
        XCTAssertTrue(home.contains("DockedSheet(detent: $whereToDetent"), "Home's Where to? docks on the bar")
        XCTAssertFalse(home.contains(".sheet("), "Where to? is no system sheet any more")
    }

    /// G3 small titles, G12 the settings button on Home only (prices stay in Settings)
    func test_G3_G12_titlesAndSettingsButton() throws {
        for file in ["UI/Rides/RidesListView.swift", "UI/Routes/RoutesListView.swift", "UI/Stats/StatsView.swift", "UI/Scooter/ScooterTabView.swift", "UI/Home/HomeView.swift"] {
            XCTAssertTrue(try text(file).contains(".navigationBarTitleDisplayMode(.inline)"), "\(file): small inline title (G3)")
        }
        XCTAssertTrue(try text("UI/Shared/DesignSystem.swift").contains(".navigationBarTitleDisplayMode(.inline)"), "list screens: small titles")
        XCTAssertTrue(try text("UI/Home/HomeView.swift").contains("GlassIcon(symbol: \"gearshape\")"))
        for file in ["UI/Rides/RidesListView.swift", "UI/Routes/RoutesListView.swift", "UI/Stats/StatsView.swift", "UI/Scooter/ScooterTabView.swift"] {
            XCTAssertFalse(try text(file).contains("symbol: \"gearshape\""), "\(file): settings only on Home (G12)")
        }
        XCTAssertFalse(try text("UI/Stats/StatsView.swift").contains("symbol: \"slider.horizontal.3\""), "Stats has no prices button (G12)")
        XCTAssertTrue(try text("UI/Settings/SettingsView.swift").contains("CostSettingsView()"), "prices stay in Settings")
    }

    /// the shared components the next chunks build on exist, each with a doc comment
    func test_sharedComponentsExist() throws {
        let c = try text("UI/Shared/Components.swift")
        for name in ["struct StatTile", "struct InfoChip", "struct StatusPill", "struct SectionHeader", "struct InfoButton"] {
            guard let r = c.range(of: name) else { XCTFail("\(name) missing"); continue }
            XCTAssertTrue(c[..<r.lowerBound].suffix(400).contains("///"), "\(name) has a doc comment")
        }
    }
}
