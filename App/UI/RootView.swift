import CorckieCore
import SwiftUI

/// Tab bar per IA.md (Routes · Rides · Home · Stats · Scooter); screens arrive in P5.
struct RootView: View {
    @State private var tab = 2
    @State private var coverShown = false
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    init() {
        Theme.applyRoundedTitles()   // F-15: rounded navigation titles, before the first bar is made
    }

    var body: some View {
        // G4 (P6-2): the version shows only in Settings → About now, no longer on every screen.
        content.themeRoot().sunlightRoot()
            .buildStamp()   // F-30: the build number above the home indicator, on every screen
            .onAppear { MapSnapshotStore.shared.refresh() }
            .onChange(of: scenePhase) { _, p in if p == .active { MapSnapshotStore.shared.refresh() } }
            .onChange(of: PhoneSensors.shared.roundedLocation.map { "\($0.lat),\($0.lon)" }) { _, _ in MapSnapshotStore.shared.refresh() }
    }

    /// M1-12: read in the body, so the cover follows the recorder (observation)
    private var liveCoverShown: Bool { RecorderService.shared.rideActive || RecorderService.shared.readyRequested }

    private var summaryShown: Bool { RecorderService.shared.summaryRideId != nil }

    @ViewBuilder private var content: some View {
        if let error = model.databaseError {
            DataUpdateFailedView(message: error)
        } else if let shot = UIShot.requested, shot != "home" {   // "home" = the real tab bar
            UIShot.screen(shot)
                .dynamicTypeSize(UIShot.bigType ? DynamicTypeSize.accessibility3 : DynamicTypeSize.large)
        } else {
            tabs
                .fullScreenCover(isPresented: Binding(get: { coverShown }, set: { _ in })) {
                    // M1-12: no tab bar, no navigation, no swipe-down while a ride is on.
                    // M1-13: when the ride is over the same cover turns into its summary.
                    RideCover()
                        .environment(\.hasFloatingTabBar, false)
                        .presentationBackground(StartTransition.shared.visible ? Color.clear : Color(.systemBackground))   // A3: the Home disc shows until the reveal
                }
                .onChange(of: liveCoverShown || summaryShown, initial: true) { _, shown in
                    // A3: while Start plays the cover appears without its slide-up; the live view reveals itself through the circle
                    var t = Transaction()
                    t.disablesAnimations = shown && StartTransition.shared.visible
                    withTransaction(t) { coverShown = shown }
                }
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 0) {
                        if model.simulator.running || ScreenSimulator.shared.active {
                            Banner(text: "SIMULATED · fake scooter replay", tint: .purple)
                        }
                        if model.database?.isReadOnly == true {
                            Banner(text: "Install the newest build · your data is from a newer version (read-only)")
                        }
                    }
                }
        }
    }

    /// Tapping the tab you are on rebuilds it, which brings it back to its first screen.
    @State private var rootTokens = [0, 0, 0, 0, 0]

    private var tabs: some View {
        // The system tab bar is hidden: the flat floating bar over it replaces it (owner Q1 S, F-14). TabView stays
        // underneath, so every tab keeps its own stack and its on-appear refresh.
        TabView(selection: $tab) {
            RoutesListView()
                .tabBarClearance()
                .stiffBounce()
                .id(rootTokens[0])
                .toolbar(.hidden, for: .tabBar)
                .tag(0)
            RidesListView()
                .tabBarClearance()
                .stiffBounce()
                .id(rootTokens[1])
                .toolbar(.hidden, for: .tabBar)
                .tag(1)
            HomeView()
                .tabBarClearance()
                .stiffBounce()
                .id(rootTokens[2])
                .toolbar(.hidden, for: .tabBar)
                .tag(2)
            StatsView()
                .tabBarClearance()
                .stiffBounce()
                .id(rootTokens[3])
                .toolbar(.hidden, for: .tabBar)
                .tag(3)
            ScooterTabView()
                .tabBarClearance()
                .stiffBounce()
                .id(rootTokens[4])
                .toolbar(.hidden, for: .tabBar)
                .tag(4)
        }
        .floatingTabBar(selection: $tab, onReselect: { rootTokens[$0] += 1 })
        .onChange(of: model.requestedTab) { _, v in
            if let v { tab = v; model.requestedTab = nil }
        }
    }

    private func placeholder(_ title: String, _ symbol: String) -> some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: symbol,
                                   description: Text("Arrives with the first milestone (M1)."))
                .navigationTitle(title)
                .screen(title)
        }
        .tabItem { Label(title, systemImage: symbol) }
    }
}

/// DATA_MODEL V4: never run on half-migrated data.
struct DataUpdateFailedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Data update failed").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text("Your rides are safe: a copy was made before the update. Send the report to Claude.\n\n\(message)")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ShareLink(item: "CorckieApp \(AppInfo.versionLine) · data update failed\n\(message)") {
                Label("Send report", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .glassCard(radius: DS.Radius.hero, padding: 16)
        .padding(DS.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background { MapBackdrop().ignoresSafeArea() }
    }
}

/// A one-line banner under the status bar (STATES patterns).
struct Banner: View {
    let text: String
    var tint: Color = .orange

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal)
            .background(tint.opacity(0.9))
            .foregroundStyle(.white)
    }
}

/// CI ui-shots: `-uiShot <screen>` opens one screen straight away (TESTING §7).
enum UIShot {
    /// What was asked for, as typed: `sun-<screen>` = the sunlight style, `xxl-<screen>` = the largest accessibility text size (M6-03 / M6-04),
    /// `dark-<screen>` = dark mode (P6-2, theme v2)
    static var raw: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiShot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var requested: String? {
        guard let r = raw else { return nil }
        for p in ["sun-", "xxl-", "dark-"] where r.hasPrefix(p) { return String(r.dropFirst(p.count)) }
        return r
    }

    static var bigType: Bool { raw?.hasPrefix("xxl-") == true }

    /// `sun-...` forces the sunlight style
    static var sunlight: Bool { raw?.hasPrefix("sun-") == true }

    /// `dark-...` forces dark mode
    static var dark: Bool { raw?.hasPrefix("dark-") == true }

    /// Every screen name the ui-shots and the check u44 open (M6-05). New states are added here and to the ui-shots list in ci.yml.
    static let allNames: [String] = [
        "settings", "settings-full", "settings-data", "export", "restore", "developer", "checks", "results", "simulator", "outside", "scooter", "rides", "rides-list", "rides-long", "home-bottom",
        "ride-detail", "ride-nogps", "ride-gap", "ride-walk", "ride-detail-full", "ride-layer-speed", "ride-layer-hills", "ride-layer-wind", "ride-save-route", "ride-prompt", "ride-insights", "replay", "ride-charts-full",
        "ride-compare", "ride-merge", "ride-trim", "routes-empty", "routes-list", "routes-greyed", "route-card", "route-card-sparse", "places", "places-map", "place-detail", "place-add", "rides-colours",
        "rides-sort-destination", "rides-sort-dayofweek", "rides-sort-timeofday", "rides-sort-distance", "rides-sort-duration", "rides-sort-battery",
        "route-arriveby", "past-weeks", "stats-week", "stats-month", "stats-rolling", "stats-empty", "week-card", "factors", "factors-sparse",
        "scooter-tab", "scooter-tab-off", "scooter-tab-none", "scooter-tab-photo", "info-money", "info-overall", "battery-page", "battery-page-empty", "battery-page-calibrated",
        "onboarding1", "onboarding2", "onboarding3",
        "live-riding", "live-ready", "live-starting", "live-fast", "live-gps", "live-nogps", "live-offline", "live-banner",
        "live-arrival", "live-routegps",
        "home-first", "home-notconnected", "home-ready", "home-parked", "home-cantfind", "home-riding", "home-location", "home-crash", "home-whereto",
        "ride-missing", "replay-missing", "data-failed", "home-simulated", "home-readonly", "stats-first-week", "export-empty", "stats-overall", "price-history", "purchase",
        "stats-insights", "insights-learning", "insight-detail", "insight-detail-departure", "insight-detail-creep", "insight-detail-wind", "home-today"
    ]

    @ViewBuilder static func screen(_ name: String) -> some View {
        NavigationStack {
            switch name {
            case "settings": SettingsView()
            case "settings-full": SettingsView()
            case "settings-data": SettingsView(startAt: "Data & backup")
            case "export": ExportEverythingView()
            case "restore": RestoreView()
            case "developer": DeveloperView()
            case "checks": ChecksView()
            case "results": ResultsView()
            case "simulator": SimulatorView()
            case "rides": RidesListView()
            case "rides-list": RidesListView(preview: RidesPreview.list())
            case "rides-long":
                RidesListView(preview: RidesPreview.long())
                    .tabBarClearance()
                    .floatingTabBar(selection: .constant(1))
            case "home-bottom":
                HomeView(preview: HomePreview.input("home-ready"))
                    .tabBarClearance()
                    .floatingTabBar(selection: .constant(2))
            case "ride-detail", "ride-nogps", "ride-gap", "ride-walk":
                RideDetailView(rideId: nil, preview: RideDetailPreview.model(name))
                    .floatingTabBar(selection: .constant(1))
            case "routes-empty", "routes-list", "routes-greyed":
                RoutesListView(preview: RoutesPreview.list(name))
            case "route-card", "route-card-sparse":
                RouteCardView(preview: RoutesPreview.card(name))
                    .floatingTabBar(selection: .constant(0))
            case "places", "places-map":
                PlacesView(preview: RoutesPreview.places())
            case "place-detail":
                PlaceMapView(placeId: nil, preview: RoutesPreview.places()[0])
            case "place-add":
                PlaceAddView(preview: true)
            case "rides-colours":
                RidesListView(preview: RidesPreview.coloured(), previewColours: RidesPreview.placeColours)
            case "rides-sort-destination", "rides-sort-dayofweek", "rides-sort-timeofday", "rides-sort-distance", "rides-sort-duration", "rides-sort-battery":
                RidesListView(preview: RidesPreview.long(), previewSort: RidesPreview.sort(name))
            case "ride-layer-speed", "ride-layer-hills", "ride-layer-wind":
                RideDetailView(rideId: nil, preview: RideDetailPreview.model("ride-detail"), previewSeries: RideDetailPreview.series(),
                               previewLayer: name == "ride-layer-hills" ? .hills : (name == "ride-layer-wind" ? .wind : .speed))
                    .floatingTabBar(selection: .constant(1))
            case "ride-detail-full":
                RideDetailView(rideId: nil, preview: RideDetailPreview.model("ride-detail"), previewSeries: RideDetailPreview.series())
                    .floatingTabBar(selection: .constant(1))
            case "ride-save-route":
                RideDetailView(rideId: nil, preview: RideDetailPreview.model("ride-detail"),
                               previewOffer: RouteOfferModel.make(routeId: "preview", state: .suggested, title: "Route 1", ridesOnRoute: 2))
            case "ride-prompt":
                RideDetailView(rideId: nil, preview: RideDetailPreview.model("ride-detail"),
                               previewPrompt: SmartPromptCard(rideId: "preview", text: "This ride used 4% more battery than usual. Wind, rush hour and load don't explain it. Anything different?",
                                                              extraPct: 4, answers: SmartAnswer.allCases))
            case "ride-insights":
                RideDetailView(rideId: nil, preview: RideDetailPreview.model("ride-detail"),
                               previewInsights: RankedInsights(
                                top: Insight(type: .q4After, rideId: "p", routeId: "A", text: "1:10 min slower than usual: headwind (~1:00 min).", basedOnN: 8, createdAt: 1_790_000_000_000),
                                more: [Insight(type: .q15After, rideId: "p", routeId: "A", text: "Headwind cost you ~1 min and ~1% battery today.", basedOnN: 9, createdAt: 1_790_000_000_000)],
                                progress: [Insight(type: .q15After, rideId: "p", routeId: "A", text: "Rain on Seed commute: 1 of 3 wet rides", basedOnN: 1, isProgress: true, createdAt: 1_790_000_000_000)]))
            case "replay":
                ReplayView(rideId: nil, previewData: ReplayDataLoader.sample())
            case "ride-charts-full":
                RideChartsFullScreen(points: RideDetailPreview.series().points)
            case "ride-compare":
                CompareSheet(rideId: "a", preview: RideToolsPreview.compare())
            case "ride-merge":
                MergeSheet(rideId: "b", previousId: "a", offer: RideToolsPreview.mergeOffer, preview: RideToolsPreview.merge())
            case "ride-trim":
                TrimSheet(rideId: "x", previewSamples: RideToolsPreview.samples())
            case "info-money":
                InfoSheet(title: "Money", info: StatsView.moneyInfo(StatsPreview.model("stats-week"))).background(Theme.background)
            case "info-overall":
                InfoSheet(title: "Overall", info: InfoFormula.overall(StatsPreview.overall())).background(Theme.background)
            case "past-weeks":
                NavigationStack { PastWeeksView(weeks: WeekPreview.weeks(), bars: WeekPreview.bars()) }
            case "ride-missing": RideDetailView(rideId: "missing-ride")
            case "replay-missing": ReplayView(rideId: "missing-ride")
            case "data-failed": DataUpdateFailedView(message: "Made-up message for the screenshot")
            case "home-simulated":
                VStack(spacing: 0) { Banner(text: "SIMULATED \u{00B7} fake scooter replay", tint: .purple); HomeView() }
            case "home-readonly":
                VStack(spacing: 0) { Banner(text: "Install the newest build \u{00B7} your data is from a newer version (read-only)"); HomeView() }
            case "export-empty": ExportEverythingView(previewEmpty: true)
            case "stats-week", "stats-month", "stats-rolling", "stats-empty", "week-card", "stats-first-week":
                StatsView(preview: StatsPreview.model(name))
            case "stats-insights", "insights-learning", "insight-detail", "insight-detail-departure", "insight-detail-creep", "insight-detail-wind":
                InsightsPreview.screen(name)   // F-21
            case "home-today":
                HomeView(preview: HomePreview.input("home-ready"), previewToday: InsightsPreview.card(.wind))
                    .floatingTabBar(selection: .constant(2))
            case "price-history": PriceHistoryView()
            case "purchase": PurchaseSettingsView()
            case "stats-overall":
                ScrollView { OverallSection(stats: StatsPreview.overall()).padding(16) }
                    .background { MapBackdrop().ignoresSafeArea() }
            case "factors", "factors-sparse":
                NavigationStack { FactorsView(preview: FactorsPreview.rows(name)) }
            case "route-arriveby":
                ScrollView { ArriveByCard(routeId: nil, destination: "Work", rides: RoutesPreview.arriveByRides(), preview: true).padding() }
            case "scooter-tab", "scooter-tab-off", "scooter-tab-none", "scooter-tab-photo":
                ScooterTabView(preview: ScooterPreview.make(name))
            case "battery-page", "battery-page-empty", "battery-page-calibrated":
                BatteryView(preview: BatteryPreview.make(name))
            case "outside": OutsideDataView()
            case "scooter": ScooterCheckView()
            case "onboarding1": OnboardingView(previewFound: true) { _ in }
            case "onboarding2": OnboardingView(startAt: .location, previewFound: true) { _ in }
            case "onboarding3": OnboardingView(startAt: .notifications, previewFound: true) { _ in }
            default:
                if let live = LivePreview.make(name) {
                    LiveRideView(preview: live).liveDark()
                } else if let input = HomePreview.input(name) {
                    // the shots show the floating tab bar too (as in the real app)
                    HomeView(preview: input, previewChips: HomePreview.chips(name),
                             previewSelected: name.hasPrefix("home-whereto") || name == "home-quick" ? "place:m" : nil,
                             previewSheet: name == "home-whereto-sheet",
                             previewParked: name == "home-parked" ? CGPoint(x: 0.76, y: 0.36) : nil,
                             previewQuick: HomePreview.quick(name))
                        .floatingTabBar(selection: .constant(2))
                } else {
                    HomeView()
                }
            }
        }
    }
}

/// M1-12 / M1-13: the full-screen cover shows the live view while a ride (or Ready) is on, then the ride's summary.
struct RideCover: View {
    var body: some View {
        cover.safeAreaInset(edge: .top, spacing: 0) {
            if ScreenSimulator.shared.active {
                Banner(text: "SIMULATED · fake scooter replay", tint: .purple)
            }
        }
    }

    @ViewBuilder private var cover: some View {
        let service = RecorderService.shared
        if service.rideActive || service.readyRequested {
            LiveRideView().liveDark().startReveal()   // A3
        } else if let id = service.summaryRideId {
            NavigationStack {
                RideDetailView(rideId: id, onDone: { RecorderService.shared.dismissSummary() })
            }
            .interactiveDismissDisabled(true)
        }
    }
}
