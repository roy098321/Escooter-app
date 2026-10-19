import CorckieCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// H7: the backup folder picker straight from the banner
    @State private var pickingBackup = false
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
                    NavigationLink { BatteryView() } label: { statusPill(m) }.buttonStyle(.plain)
                } else {
                    statusPill(m)
                }
                if m.showLocationCard { locationCard }
                startDisc(m)
                if m.state != .riding { loadRow }
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

    /// H4: one compact row, a load icon and None / +5 / +15 / kg
    private var loadRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bag.fill").foregroundStyle(Theme.canyon).accessibilityHidden(true)
                GlassSegmented(options: [(LoadLevel.none.rawValue, "None"), (LoadLevel.light.rawValue, "+\(lightKg)"),
                                         (LoadLevel.heavy.rawValue, "+\(heavyKg)"), (LoadLevel.custom.rawValue, "kg")],
                               selection: $loadLevelRaw)
                    .accessibilityLabel("Load for the next ride")
            }
            if loadLevelRaw == LoadLevel.custom.rawValue {
                TextField("kg", text: $exactKg)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Exact load in kilograms")
            }
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

    /// H3: one small pill, icon + short state + battery % (and "seen 16:33" when the scooter is not connected)
    private func statusPill(_ m: HomeModel) -> some View {
        let on = m.state == .ready || m.state == .riding
        return StatusPill(symbol: on ? "scooter" : "wifi.slash", text: HomeCopy.statusText(m), tint: on ? Theme.ok : Theme.canyon,
                          value: m.batteryText)
            .opacity(m.greyed ? 0.7 : 1)
    }

    /// The 170 pt round Start / Connect disc (amber for Connect and Try again, as before). The tap goes through `primaryTapped`, unchanged.
    private func startDisc(_ m: HomeModel) -> some View {
        let amber = m.primary == .connect || m.primary == .tryAgain
        let tint: Color = amber ? Theme.accentSoft : Theme.accent
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
                        Text(HomeCopy.buttonWord(m.primary, connecting: m.state == .connecting))
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

    /// H7: one line and a button that opens the folder picker right here
    private var backupCard: some View {
        HStack(spacing: 10) {
            Label("Not backed up", systemImage: "externaldrive.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button("Choose folder") { pickingBackup = true }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: DS.hit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .orange)
        .fileImporter(isPresented: $pickingBackup, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): BackupFolder.shared.remember(url)
            case .failure(let error): Log.error(source: "backup", "Pick failed: \(error.localizedDescription)")
            }
        }
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
            row("No destination", chip: nil, on: selected == nil) { onPick(nil) }
            ForEach(chips, id: \.routeId) { c in
                row(c.label, chip: c, on: c.routeId == selected) { onPick(c.routeId) }
            }
        }
    }

    private func row(_ title: String, chip: WhereToChip?, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(on ? .semibold : .regular))
                    if let c = chip, let t = c.timeText, let a = c.arriveText {
                        HStack(spacing: 6) {
                            InfoChip("timer", t, label: "Time")
                            InfoChip("flag.checkered", a, label: "Arrive")
                            if let u = c.usedText { InfoChip("battery.50percent", u, label: "Battery used") }
                        }
                    }
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
        var work = WhereToChip(routeId: "a", label: "Work", detail: "Work")
        work.timeText = "13 min"; work.arriveText = "8:56"; work.usedText = "11%"
        var home = WhereToChip(routeId: "b", label: "Home", detail: "Home")
        home.timeText = "14 min"; home.arriveText = "9:02"; home.usedText = "12%"
        return [work, home]
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

/// The short Home words (H2, H3), kept apart so the automatic check u64 can test them.
enum HomeCopy {
    /// H2: one word on the big button
    static func buttonWord(_ p: HomePrimary, connecting: Bool) -> String {
        if connecting { return "Connecting\u{2026}" }
        switch p {
        case .connect: return "Connect"
        case .startRide: return "Start"
        case .tryAgain: return "Try again"
        case .openRide: return "Live view"
        }
    }

    /// H3: the state in two or three words, "seen 16:33" when the scooter is not connected
    static func statusText(_ m: HomeModel) -> String {
        switch m.state {
        case .noScooter: return "No scooter"
        case .notConnected:
            let seen = m.detail.hasPrefix("last seen") ? " \u{00B7} " + String(m.detail.dropFirst(5)) : ""
            return "Not connected" + seen
        case .connecting: return "Connecting\u{2026}"
        case .cantFind: return "Can't find it"
        case .ready: return "Connected"
        case .riding: return "Riding"
        }
    }
}
