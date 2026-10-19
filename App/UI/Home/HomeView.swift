import CorckieCore
import SwiftUI

/// M1-11 Home (IA: Home tab). States per STATES S1 / S2: first use and not connected show the amber
/// "Connect your scooter" (never Start ride); connected shows the status card + Start ride; a failed connect
/// says "Can't find the scooter" after 30 s with Try again; a ride in progress says so. The rules live in
/// `HomeLogic` (CorckieCore, unit tested); this view only shows the model.
/// UI overhaul (UI_PLAN 3.1): glass cards over the map backdrop, the 170 pt round Start / Connect disc, a Where to? sheet.
struct HomeView: View {
    /// ui-shots: a made-up input instead of the real app state
    var preview: HomeInput?
    /// ui-shots: made-up Where to? chips and the chosen one
    var previewChips: [WhereToChip]?
    var previewSelected: String?
    /// ui-shots: open the Where to? sheet straight away
    var previewSheet = false

    /// the disc is 170 pt at normal text size and grows with Dynamic Type (capped at 270 pt)
    @ScaledMetric(relativeTo: .title3) private var discSize: CGFloat = 170
    @State private var chips: [WhereToChip] = []
    @State private var now = Date()
    @State private var connectingSince: Date?
    @State private var discTap = 0
    @State private var showOnboarding = false
    /// B19: the Where to? sheet docks on the tab bar (closed = one line "Where to? · Work")
    @State private var whereToDetent: SheetDetent = .peek
    @State private var crashDismissed = false
    @State private var lastRide: RideListItem?
    @State private var oldestRideMs: Int64?
    /// F-02: the Load for the next ride (None / Light / Heavy / Exact), kept until the next ride starts
    @State private var loadLevelRaw = LoadLevel.none.rawValue
    @State private var exactKg = ""
    @State private var loadReady = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var input: HomeInput {
        if let preview { return preview }
        let scooter = AppModel.shared.scooter
        let seen = LastSeen.load()
        let simulated = ScreenSimulator.shared.active
        return HomeInput(paired: scooter.hasKnownScooter || simulated, connected: scooter.connected || simulated,
                         connectingSinceS: connectingSince?.timeIntervalSince1970,
                         nowS: now.timeIntervalSince1970,
                         batteryPct: scooter.frame?.batteryPct ?? (simulated ? RecorderService.shared.live?.batteryPct : nil),
                         lastSeenMs: seen.ms, lastSeenPct: seen.pct,
                         utcOffsetMin: TimeZone.current.secondsFromGMT() / 60,
                         rideActive: RecorderService.shared.rideActive,
                         locationAlways: PermissionsCheck.shared.locationStatus == .authorizedAlways,
                         lastRunCrashed: CrashCatcher.shared.lastRunCrashed && !crashDismissed,
                         lastRide: lastRide)
    }

    var body: some View {
        NavigationStack {
            homeScreen(HomeLogic.model(input))
                .background { MapBackdrop(map: true).ignoresSafeArea() }
                .navigationTitle("Home")
                .navigationBarTitleDisplayMode(.inline)
                .screen("Home")
                .toolbar {
                    // G3: no page title on Home, the app mark + name small (theme v2 mock-up)
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    ToolbarItem(placement: .topBarLeading) { brand }
                    // G12: the only settings button of the app
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            GlassIcon(symbol: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
        .onAppear {
            loadSelectorFromStore()
            reloadLastRide()
            if previewSheet { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { whereToDetent = .half } }
        }
        .onChange(of: ScreenSimulator.shared.active) { _, _ in lastRide = nil; reloadLastRide() }
        .onChange(of: RecorderService.shared.summaryRideId) { _, _ in reloadLastRide() }
        .onChange(of: RecorderService.shared.rideActive) { _, active in if !active { loadReady = false; loadSelectorFromStore() } }
        .onReceive(tick) { now = $0 }
        .onChange(of: AppModel.shared.scooter.connected) { _, connected in
            if connected { connectingSince = nil }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(onFinish: { _ in
                showOnboarding = false
                reloadLastRide()
            })
        }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Image("AppMark")
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text("CorckieApp")
                .font(.headline)
                .fontDesign(.rounded)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The scroll content, with the Where to? sheet docked on the tab bar while there are routes to pick (B19)
    private func homeScreen(_ m: HomeModel) -> some View {
        let docked = !shownChips.isEmpty && m.state != .riding
        return content(m, dockRoom: docked)
            .overlay {
                if docked {
                    DockedSheet(detent: $whereToDetent, summary: whereToSummary) {
                        WhereToSheet(chips: shownChips, selected: selectedRoute) { id in
                            pickRoute(id)
                            whereToDetent = .peek
                        }
                    }
                }
            }
    }

    private func content(_ m: HomeModel, dockRoom: Bool) -> some View {
        ScrollView {
            VStack(spacing: DS.Space.block) {
                if m.showCrashBanner { crashCard }
                if backupBannerShown { backupCard }
                if let n = EdgeWatch.shared.expiryNotice { noticeCard(n, symbol: "clock.badge.exclamationmark") }
                if let n = EdgeWatch.shared.storageNotice { noticeCard(n, symbol: "internaldrive") }
                if m.batteryText != nil {
                    NavigationLink { BatteryView() } label: { statusCard(m) }.buttonStyle(.plain)
                } else {
                    statusCard(m)
                }
                if m.showLocationCard { locationCard }
                startDisc(m)
                if m.state != .riding { loadSelector }
                // room for the docked Where to? line above the tab bar
                if dockRoom { Color.clear.frame(height: SheetDock.handle + SheetDock.summary + 8) }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, DS.Space.block)
        }
        .defaultScrollAnchor(UIShot.requested == "home-bottom" ? .bottom : nil)   // the ui-shot of the very bottom (B23)
    }

    // MARK: Load for the next ride (F-02)

    private var lightKg: Int { Int((RiderSettings.kg(AppModel.shared.database, .light) ?? 5).rounded()) }
    private var heavyKg: Int { Int((RiderSettings.kg(AppModel.shared.database, .heavy) ?? 15).rounded()) }

    private var loadSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Load for the next ride").font(.subheadline.weight(.semibold))
            GlassSegmented(options: [(LoadLevel.none.rawValue, "None"), (LoadLevel.light.rawValue, "Light \(lightKg) kg"),
                                     (LoadLevel.heavy.rawValue, "Heavy \(heavyKg) kg"), (LoadLevel.custom.rawValue, "Exact")],
                           selection: $loadLevelRaw)
                .accessibilityLabel("Load for the next ride")
            if loadLevelRaw == LoadLevel.custom.rawValue {
                TextField("kg", text: $exactKg)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Exact load in kilograms")
            }
            Text("Goes onto the next ride when it starts, then resets to None. You can change it on the ride summary.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .onChange(of: loadLevelRaw) { _, _ in saveLoad() }
        .onChange(of: exactKg) { _, _ in saveLoad() }
    }

    private func loadSelectorFromStore() {
        guard preview == nil else { return }
        let c = PendingLoad.get(AppModel.shared.database)
        loadLevelRaw = c.level.rawValue
        exactKg = c.level == .custom ? String(c.customKg) : ""
        DispatchQueue.main.async { loadReady = true }
    }

    private func saveLoad() {
        guard preview == nil, loadReady else { return }
        let level = LoadLevel(rawValue: loadLevelRaw) ?? .none
        let kg = Double(exactKg.replacingOccurrences(of: ",", with: ".")) ?? 0
        PendingLoad.set(AppModel.shared.database, LoadChoice(level: level, customKg: min(max(kg, 0), LoadChoice.maxKg)))
    }

    private func statusCard(_ m: HomeModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: m.state == .ready || m.state == .riding ? "scooter" : "wifi.slash")
                    Text(m.title).font(.headline)
                }
                Text(m.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let battery = m.batteryText {
                Text(battery)
                    .scaledFont(40, weight: .bold, mono: true, relativeTo: .largeTitle)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(m.greyed ? 0.7 : 1)
        .glassCard(radius: DS.Radius.hero, padding: 18)
        .accessibilityElement(children: .combine)
    }

    /// The 170 pt round Start / Connect disc (amber for Connect and Try again, as before). The tap goes through `primaryTapped`, unchanged.
    private func startDisc(_ m: HomeModel) -> some View {
        let amber = m.primary == .connect || m.primary == .tryAgain
        let tint: Color = amber ? .orange : Theme.accent
        return VStack(spacing: 14) {
            Button {
                discTap += 1
                primaryTapped(m.primary)
            } label: {
                ZStack {
                    Circle().fill(tint.opacity(0.2)).frame(width: min(discSize, 270) + 24, height: min(discSize, 270) + 24)
                    VStack(spacing: 8) {
                        if m.state == .connecting {
                            ProgressView().controlSize(.large).tint(Theme.onAccent)
                        } else {
                            Image(systemName: discSymbol(m.primary)).font(.system(size: 40, weight: .semibold))
                        }
                        Text(m.primaryTitle)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                            .lineLimit(3)
                    }
                    .foregroundStyle(Theme.onAccent)   // F-15: dark text on the orange (white is only 2.3:1)
                    .padding(20)
                    .frame(width: min(discSize, 270), height: min(discSize, 270))
                    .background(tint, in: Circle())
                    .shadow(color: tint.opacity(0.35), radius: 14, y: 6)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!m.primaryEnabled)
            .sensoryFeedback(.impact(weight: .heavy), trigger: discTap)
            .opacity(m.primaryEnabled ? 1 : 0.6)
            .accessibilityLabel(m.primaryTitle)
            if m.state == .ready || m.state == .notConnected || m.state == .cantFind {
                Text(m.state == .ready ? "Rides also start on their own as soon as the wheel turns." : "Rides start only once the scooter is connected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func discSymbol(_ p: HomePrimary) -> String {
        switch p {
        case .startRide: return "play.fill"
        case .connect: return "dot.radiowaves.left.and.right"
        case .tryAgain: return "arrow.clockwise"
        case .openRide: return "scooter"
        }
    }

    // MARK: Where to? (M2-06): a row that opens a sheet with one choice per saved route; hidden until a route exists (S2)

    private var shownChips: [WhereToChip] { previewChips ?? chips }
    private var selectedRoute: String? { preview != nil ? previewSelected : RouteFollowSelection.shared.routeId }

    private func pickRoute(_ id: String?) {
        guard preview == nil else { return }
        if let id {
            if selectedRoute != id { RouteFollowSelection.shared.toggle(id) }
        } else {
            RouteFollowSelection.shared.routeId = nil
        }
    }

    /// the closed line of the docked sheet
    private var whereToSummary: String {
        let chosen = shownChips.first(where: { $0.routeId == selectedRoute })
        return "Where to? \u{00B7} \(chosen?.label ?? "No destination")"
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Location is not set to Always", systemImage: "location.slash")
                .font(.subheadline.weight(.semibold))
            Text("Rides start on their own only while the app is open. Start ride still works.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Open iPhone Settings") { PermissionsCheck.openSettings() }
                .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .orange)
    }

    /// M1-16 (C13 S3): 14 days without a backup
    private var backupBannerShown: Bool {
        guard preview == nil else { return false }
        return BackupPlan.bannerShown(lastBackupMs: BackupWriter.shared.lastBackupMs, oldestRideMs: oldestRideMs,
                                      nowMs: Int64(now.timeIntervalSince1970 * 1000))
    }

    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(BackupPlan.bannerText(hasFolder: BackupFolder.shared.hasFolder), systemImage: "externaldrive.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))
            NavigationLink("Backup folder") { BackupView() }
                .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .orange)
    }

    /// M6-06 (C28): the 7-day expiry and phone storage
    private func noticeCard(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: .orange)
    }

    private var crashCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The app closed unexpectedly last time", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            HStack {
                NavigationLink("Report a problem") { ReportProblemView() }
                Spacer()
                Button("Dismiss") { crashDismissed = true }
            }
            .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .red)
    }

    private func primaryTapped(_ p: HomePrimary) {
        guard preview == nil else { return }
        switch p {
        case .connect:
            if input.paired { startConnecting() } else { showOnboarding = true }
        case .tryAgain:
            startConnecting()
        case .startRide:
            RecorderService.shared.press(.startPressed)
        case .openRide:
            break   // M1-12: the live view opens by itself while a ride is on
        }
    }

    private func startConnecting() {
        connectingSince = Date()
        AppModel.shared.scooter.start()
    }

    private func reloadLastRide() {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        chips = RouteFollowLoader.chips(database: db)
        if let id = RouteFollowSelection.shared.routeId, !chips.contains(where: { $0.routeId == id }) { RouteFollowSelection.shared.routeId = nil }
        oldestRideMs = try? RideQueries(db).rides().last?.startAt
        BackupWriter.shared.runIfDue()
        EdgeWatch.shared.refresh(database: db)
        guard let r = try? RideQueries(db).rides(limit: 1).first else { return }
        lastRide = RideListItem(id: r.id, startAt: r.startAt, utcOffsetMin: r.utcOffsetMin, kind: r.kind,
                                distanceM: r.distanceM, totalS: r.totalS)
    }
}

/// The content of the docked Where to? sheet (B19): "No destination" or one of the saved routes; picking one closes the sheet
/// back to its one-line state (the caller does that). UI only, the selection is `RouteFollowSelection`.
private struct WhereToSheet: View {
    let chips: [WhereToChip]
    let selected: String?
    let onPick: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.row) {
            row("No destination", detail: nil, on: selected == nil) { onPick(nil) }
            ForEach(chips, id: \.routeId) { c in
                row(c.label, detail: c.routeId == selected ? c.detail : nil, on: c.routeId == selected) { onPick(c.routeId) }
            }
        }
    }

    private func row(_ title: String, detail: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(on ? .semibold : .regular))
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if on { Image(systemName: "checkmark").foregroundStyle(Theme.accentInk) }
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .glassCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Made-up Home states for the CI ui-shots (`-uiShot home-first` and so on).
enum HomePreview {
    /// M2-06: made-up chips (no real place names)
    static func chips(_ name: String) -> [WhereToChip]? {
        guard name == "home-whereto" || name == "home-whereto-sheet" else { return nil }
        return [WhereToChip(routeId: "a", label: "Work", detail: "Work \u{00B7} today ~13 min \u{00B7} leave now, arrive ~8:56 \u{00B7} uses about 11%"),
                WhereToChip(routeId: "b", label: "Home", detail: "Home \u{00B7} today ~14 min")]
    }

    static func input(_ name: String) -> HomeInput? {
        let now = Date().timeIntervalSince1970
        let seen = Int64((now - 3 * 3600) * 1000)
        let ride = RideListItem(id: "p", startAt: seen, kind: "ride", distanceM: 6100, totalS: 1080)
        switch name {
        case "home-first":
            return HomeInput(paired: false, connected: false, nowS: now)
        case "home-notconnected":
            return HomeInput(paired: true, connected: false, nowS: now, lastSeenMs: seen, lastSeenPct: 58, lastRide: ride)
        case "home-ready", "home-whereto", "home-whereto-sheet":
            return HomeInput(paired: true, connected: true, nowS: now, batteryPct: 91, lastRide: ride)
        case "home-cantfind":
            return HomeInput(paired: true, connected: false, connectingSinceS: now - 40, nowS: now, lastSeenMs: seen, lastSeenPct: 58)
        case "home-riding":
            return HomeInput(paired: true, connected: true, nowS: now, batteryPct: 88, rideActive: true)
        case "home-location":
            return HomeInput(paired: true, connected: true, nowS: now, batteryPct: 91, locationAlways: false)
        case "home-crash":
            return HomeInput(paired: true, connected: true, nowS: now, batteryPct: 91, lastRunCrashed: true)
        default:
            return nil
        }
    }
}
