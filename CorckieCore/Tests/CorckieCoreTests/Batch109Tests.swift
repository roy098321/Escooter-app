import CorckieCore
import XCTest

/// Batch 9 guard tests (B96 + the new-rider audit of 18 Nov 2026). Logic in CorckieCore, plus checks on the app's source text
/// (Linux CI cannot build the app, like ThemeGuardTests).
final class Batch109Tests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: N9-1 · B96

    /// The ride replay sound plays out in full: no fade at the route-draw length; the line and the haptic keep `drawS`
    func test_B96_replaySoundIsNotCutShort() throws {
        let player = try text("Audio/SoundPlayer.swift")
        XCTAssertFalse(player.contains("lastingS"), "no play(_:lastingS:) that fades the sound at drawS")
        XCTAssertFalse(player.contains("setVolume(0, fadeDuration"), "nothing fades a nice sound out early")
        let detail = try text("UI/Rides/RideDetailView.swift")
        XCTAssertTrue(detail.contains("SoundPlayer.shared.play(.rideReplay)"))
        XCTAssertTrue(detail.contains("RideDrawHaptic.shared.play(speedsKmh:") && detail.contains("durationS: drawS"), "the haptic keeps drawS")
    }

    // MARK: N9-2 · first open

    func test_A01_A02_freshInstallOpensOnboarding_noWhatsNew() throws {
        XCTAssertTrue(NewRider.opensOnboarding(onboardingDone: false, paired: false))
        XCTAssertFalse(NewRider.opensOnboarding(onboardingDone: true, paired: false), "Set up later is not forced again")
        XCTAssertFalse(NewRider.opensOnboarding(onboardingDone: false, paired: true))
        XCTAssertTrue(NewRider.isFreshInstall(lastSeenWhatsNew: nil, onboardingDone: false, paired: false))
        XCTAssertFalse(NewRider.isFreshInstall(lastSeenWhatsNew: "108.131226.02", onboardingDone: false, paired: false), "an update still sees What's new")
        XCTAssertFalse(NewRider.isFreshInstall(lastSeenWhatsNew: nil, onboardingDone: true, paired: true))
        let home = try text("UI/Home/HomeView.swift")
        XCTAssertTrue(home.contains("firstLaunch()") && home.contains("WhatsNewStore.markSeen()"))
        XCTAssertTrue(home.contains("OnboardingView(welcome: onboardingWelcome"))
    }

    func test_A03_A04_outsideDataWaits_holidaysByRegion() throws {
        XCTAssertFalse(NewRider.outsideDataAllowed(onboardingDone: false, paired: false, locationAllowed: true))
        XCTAssertFalse(NewRider.outsideDataAllowed(onboardingDone: true, paired: false, locationAllowed: false))
        XCTAssertTrue(NewRider.outsideDataAllowed(onboardingDone: true, paired: false, locationAllowed: true))
        XCTAssertTrue(NewRider.outsideDataAllowed(onboardingDone: false, paired: true, locationAllowed: true), "riders from before onboarding")
        XCTAssertTrue(NewRider.usesHebcalHolidays(regionCode: "IL"))
        XCTAssertFalse(NewRider.usesHebcalHolidays(regionCode: "US"))
        XCTAssertFalse(NewRider.usesHebcalHolidays(regionCode: nil))
        let service = try text("OutsideData/OutsideDataService.swift")
        XCTAssertTrue(service.contains("NewRider.outsideDataAllowed(") && service.contains("NewRider.usesHebcalHolidays("))
    }

    func test_A05_buildStampOff() throws {
        XCTAssertTrue(try text("UI/Shared/BuildStamp.swift").contains("static let isVisible = false"))
        XCTAssertTrue(try text("UI/Settings/SettingsView.swift").contains("LabeledContent(\"Version\") { VersionLabel() }"))
    }

    func test_A10_A27_quietDayZeroHome() throws {
        XCTAssertFalse(NewRider.showsLoadRow(rides: 2))
        XCTAssertTrue(NewRider.showsLoadRow(rides: 3))
        XCTAssertFalse(NewRider.showsWhereTo(rides: 0, places: 0))
        XCTAssertTrue(NewRider.showsWhereTo(rides: 0, places: 1))
        XCTAssertTrue(NewRider.showsWhereTo(rides: 1, places: 0))
        let home = try text("UI/Home/HomeView.swift")
        XCTAssertTrue(home.contains("showsLoad { loadRow }") && home.contains("showsWhereTo { whereToRow"))
    }

    // MARK: N9-2 · setup and empty app

    func test_A07_cantFindAfter30s_inOnboarding() throws {
        XCTAssertFalse(NewRider.cantFind(searchingSinceS: 100, nowS: 129, found: false))
        XCTAssertTrue(NewRider.cantFind(searchingSinceS: 100, nowS: 130, found: false))
        XCTAssertFalse(NewRider.cantFind(searchingSinceS: 100, nowS: 500, found: true))
        XCTAssertFalse(NewRider.cantFind(searchingSinceS: nil, nowS: 500, found: false))
        let onboarding = try text("UI/Onboarding/OnboardingView.swift")
        XCTAssertTrue(onboarding.contains("cantFindBlock") && onboarding.contains("Which scooters work?"))
    }

    func test_A08_A09_A21_onboardingWords() throws {
        let onboarding = try text("UI/Onboarding/OnboardingView.swift")
        XCTAssertFalse(onboarding.contains("then Change to Always"), "A-08: no instruction for a pop-up that is not there")
        XCTAssertFalse(onboarding.contains("When you switch on"), "A-09")
        XCTAssertTrue(onboarding.contains("NewRider.locationLine") && onboarding.contains("NewRider.alertsLine") && onboarding.contains("NewRider.safetyLine"))
        XCTAssertTrue(NewRider.alertsLine.contains("scooter is ready"))
        XCTAssertFalse(try text("UI/Home/HomeView.swift").contains("Switch-on alerts"))
    }

    func test_A11_A12_A13_emptyScreensAndName() throws {
        XCTAssertTrue(try text("UI/Routes/RoutesListView.swift").contains("NewRider.emptyRoutesHint"))
        XCTAssertTrue(try text("UI/Stats/StatsView.swift").contains("NewRider.emptyStatsHint"))
        let scooter = try text("UI/Scooter/ScooterTabView.swift")
        XCTAssertTrue(scooter.contains("Text(\"Connect\")") && scooter.contains("OnboardingView {"))
        XCTAssertEqual(NewRider.cardName(foundModel: "RND G100"), "RND G100")
        XCTAssertEqual(NewRider.cardName(foundModel: nil), "Scooter")
        XCTAssertTrue(try text("AppModel.swift").contains("name: NewRider.cardName(foundModel: model)"))
    }

    func test_A18_fullAtSaysLearning() {
        let base = ChargeSession(id: "t", startPct: 40, startMs: 0)
        XCTAssertTrue(ChargeText.fullLine(base, utcOffsetMin: 0).hasSuffix("\u{00B7} learning"))
        var learned = base
        learned.ratePctPerHour = 20
        XCTAssertFalse(ChargeText.fullLine(learned, utcOffsetMin: 0).contains("learning"))
    }

    func test_A24_A26_creditsAndScaledFonts() throws {
        XCTAssertTrue(NewRider.creditsLine.contains("OpenStreetMap") && NewRider.creditsLine.contains("Open-Meteo"))
        XCTAssertTrue(try text("UI/Settings/SettingsView.swift").contains("NavigationLink(\"Credits\") { CreditsView() }"))
        for file in ["UI/Home/HomeView.swift", "UI/Onboarding/OnboardingView.swift", "UI/Onboarding/WelcomeView.swift",
                     "UI/Shared/FloatingTabBar.swift", "UI/Shared/DesignSystem.swift", "UI/Scooter/ScooterHeroCard.swift"] {
            XCTAssertFalse(try text(file).contains(".font(.system(size:"), "\(file) has a fixed font size")
        }
    }

    // MARK: N9-3 · A-06 welcome

    func test_A06_welcomeAndSevenCardTour() throws {
        XCTAssertEqual(NewRider.tour.count, 7)
        XCTAssertEqual(NewRider.tour.first?.title, "Rides record themselves")
        XCTAssertEqual(NewRider.tour.last?.title, "Find where you parked")
        XCTAssertEqual(NewRider.tourButton(card: 0), "Next")
        XCTAssertEqual(NewRider.tourButton(card: 6), "Get started")
        let welcome = try text("UI/Onboarding/WelcomeView.swift")
        XCTAssertTrue(welcome.contains("accessibilityReduceMotion") && welcome.contains("guard !reduceMotion"), "no zoom with Reduce Motion")
        XCTAssertTrue(welcome.contains("Button(\"Skip\""))
        XCTAssertTrue(try text("UI/Settings/SettingsView.swift").contains("WelcomeView(tourOnly: true)"))
    }

    // MARK: N9-3 · A-14 / A-15 one km-left number

    func test_A14_A15_tileKmEqualsVoiceKm() throws {
        let range = RealRange(currentPct: 80, reservePct: 5, pctPerKm: 2.5, basedOnRides: 10, fromEnergy: false, lowBattery: false,
                              rangeKm: 30, decisionRangeKm: 27)
        for level in stride(from: 100.0, through: 6, by: -7) {
            let km = KmLeft.km(levelPct: level, range: range)
            let tile = KmLeft.tileText(km)
            let voice = V09Message.everyTen(pct: Int(level), kmLeft: km).line
            XCTAssertTrue(tile.contains("\(km!) km left"))
            if km! >= 2 { XCTAssertTrue(voice.contains("about \(SpokenNumber.words(km!)) kilometres left"), voice) }
        }
        XCTAssertEqual(KmLeft.km(levelPct: 80, range: range), 30)
        XCTAssertEqual(KmLeft.tileText(nil), "learning range")
        XCTAssertNil(KmLeft.km(levelPct: 80, range: nil), "no real range yet = learning")
        XCTAssertEqual(V09Message.everyTen(pct: 80).line, "Battery at eighty percent.", "learning: the plain line")
        XCTAssertEqual(V09Message.usingMore(aboveUsualPct: 15, kmLeft: 16).line, "Using fifteen percent more than usual. About sixteen kilometres left.")
        for m in V09Message.samples { XCTAssertFalse(m.line.contains("per kilometre"), "the rate is no longer spoken: \(m.line)") }
        // the app: the tile and the voice read the same LiveRange with the same rounded level
        let live = try text("UI/Live/LiveRideView.swift")
        XCTAssertTrue(live.contains("LiveRange.shared.km(levelPct:") && live.contains("KmLeft.tileText(km)") && live.contains("KmLeft.spokenText(km)"))
        XCTAssertTrue(try text("Audio/RideVoice.swift").contains("vi.kmLeft = LiveRange.shared.km(levelPct:"))
        XCTAssertTrue(try text("Recorder/LiveRange.swift").contains("$0.rounded()"))
    }

    func test_A14_batteryTileKeepsItsSafeSize() throws {
        let live = try text("UI/Live/LiveRideView.swift")
        XCTAssertTrue(live.contains("static let tilePt: CGFloat = 60"), "B21: battery stays >= 60 pt; the km line is a second line")
    }

    // MARK: N9-3 · A-16 cost + km left on the summary

    func test_A16_rideCostsAddUpToTheStatsWeek() throws {
        let day: Int64 = 86_400_000
        let t0: Int64 = 1_790_000_000_000
        let rides = (0..<6).map { StatsRide(startAt: t0 + Int64($0) * day / 2, utcOffsetMin: 120, kind: $0 == 3 ? "shortHop" : "ride",
                                             distanceM: 5_000, totalS: 900, usedPct: 8 + Double($0)) }
        for prices in [StatsPrices(packWh: 760), StatsPrices(packWh: 760, electricityIlsPerKwh: 0.7)] {
            let period = StatsCalc.period(span: .week, mode: .rolling, nowMs: t0 + 3 * day, utcOffsetMin: 120)
            let week = StatsCalc.totals(rides, period: period, prices: prices, utcOffsetMin: 120).electricityIls
            let sum = rides.reduce(0.0) { $0 + StatsCalc.rideCostIls($1, prices: prices) }
            XCTAssertEqual(sum, week, accuracy: 1e-9)
        }
        XCTAssertEqual(KmLeft.summaryText(18), "\u{2248} 18 km")
        XCTAssertEqual(KmLeft.summaryText(nil), "learning")
        let detail = try text("UI/Rides/RideDetailView.swift")
        XCTAssertTrue(detail.contains("static let keyTileCount = 8") && detail.contains("StatTileGrid(columns: 2)"))
        XCTAssertTrue(detail.contains("label: \"Cost\"") && detail.contains("label: \"km left\""))
        XCTAssertTrue(detail.contains("StatsCalc.rideCostIls(costRide, prices: StatsLoader.prices(db))"))
    }

    // MARK: N9-3 · A-17 ask before sharing

    func test_A17_trimmedExportHasNoPointNearTheEnds() throws {
        // made up, in the ocean
        let rows = (0..<80).map { i in ReplayRow(t: Double(i) * 5, lat: 0.001 * Double(i), lon: -30, speedKmh: 18, batteryPct: 70) }
        let cut = ShareTrim.hideEnds(rows)
        let first = (lat: rows.first!.lat!, lon: rows.first!.lon!), last = (lat: rows.last!.lat!, lon: rows.last!.lon!)
        for r in cut {
            guard let lat = r.lat, let lon = r.lon else { continue }
            XCTAssertGreaterThan(PrivacyExport.distanceM(lat, lon, first.lat, first.lon), 200)
            XCTAssertGreaterThan(PrivacyExport.distanceM(lat, lon, last.lat, last.lon), 200)
        }
        XCTAssertEqual(cut.count, rows.count, "the timeline stays")
        XCTAssertGreaterThan(cut.compactMap(\.lat).count, 50, "the middle stays")
        XCTAssertEqual(ShareTrim.hideEnds([]), [])
        let detail = try text("UI/Rides/RideDetailView.swift")
        XCTAssertTrue(detail.contains("confirmationDialog(ShareTrim.question") && detail.contains("askExport = .csv") && detail.contains("askExport = .gpx"))
        let replay = try text("UI/Rides/ReplayView.swift")
        XCTAssertTrue(replay.contains("confirmationDialog(ShareTrim.question") && replay.contains("download(hideEnds: true)"))
        XCTAssertFalse(replay.contains("await download() }"), "no share without the question")
        XCTAssertTrue(try text("Recorder/RideExportService.swift").contains("ShareTrim.hideEnds(all)"))
        XCTAssertTrue(try text("Recorder/ReplayDataLoader.swift").contains("ShareTrim.hideEnds(all)"))
    }
}
