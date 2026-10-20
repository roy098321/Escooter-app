import CorckieCore
import SwiftUI
import UniformTypeIdentifiers

/// M1-11 Home (IA: Home tab). States per STATES S1 / S2: first use and not connected show the amber
/// "Connect your scooter" (never Start ride); connected shows the status card + Start ride; a failed connect
/// says "Can't find the scooter" after 30 s with Try again; a ride in progress says so. The rules live in
/// `HomeLogic` (CorckieCore, unit tested); this view only shows the model.
/// UI overhaul (UI_PLAN 3.1) + P6-3: glass cards over the map backdrop, the big round Start / Connect disc (F-17: about 250 pt,
/// centred in the free space between the status pill and the bottom rows), a compact Where to? row that opens a standard iOS
/// half-height sheet (B29), the Load row below it, and the last parked spot as a pin on the map (V17).
struct HomeView: View {
    /// ui-shots: a made-up input instead of the real app state
    var preview: HomeInput?
    /// ui-shots: made-up Where to? chips and the chosen one
    var previewChips: [WhereToChip]?
    var previewSelected: String?
    /// ui-shots: open the Where to? sheet straight away
    var previewSheet = false
    /// ui-shots: a made-up parked pin (a fraction of the screen)
    var previewParked: CGPoint?
    /// ui-shots: made-up quick-dial buttons (F-29)
    var previewQuick: [QuickDialItem]?
    /// F-21: the ui-shot TODAY card
    var previewToday: InsightCard?

    /// F-17: the disc is 250 pt at normal text size and grows with Dynamic Type (capped at 300 pt)
    @ScaledMetric(relativeTo: .title3) private var discSize: CGFloat = HomeView.discBase
    @State private var chips: [WhereToChip] = []
    /// F-29: the round buttons of the quick dial
    @State private var quick: [QuickDialItem] = []
    /// B35: riding that was not recorded, until dismissed
    @State private var gap: UntrackedGap?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var now = Date()
    @State private var connectingSince: Date?
    @State private var discTap = 0
    /// A3: the disc's frame on screen (the start transition grows from its centre) and the press-in state
    @State private var discFrame: CGRect = .zero
    @State private var discPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOnboarding = false
    /// B29: the Where to? list is a standard iOS sheet
    @State private var showWhereTo = false
    /// V17: where the scooter was last parked
    @State private var parked: ParkedSpot?
    @State private var crashDismissed = false
    /// H7: the backup folder picker straight from the banner
    @State private var pickingBackup = false
    @State private var lastRide: RideListItem?
    @State private var oldestRideMs: Int64?
    /// F-02: the Load for the next ride (None / Light / Heavy / Exact), kept until the next ride starts
    @State private var loadSel = "none"
    @State private var customKg = 0
    @State private var askKg = false
    @State private var kgText = ""
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
                .background { MapBackdrop(map: true, parked: parkedForMap, parkedPreview: previewParked).ignoresSafeArea() }
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
            if previewSheet { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showWhereTo = true } }
        }
        .onChange(of: ScreenSimulator.shared.active) { _, _ in lastRide = nil; reloadLastRide() }
        .onChange(of: RecorderService.shared.summaryRideId) { _, _ in reloadLastRide() }
        .onChange(of: RecorderService.shared.rideActive) { _, active in
            if !active { loadReady = false; loadSelectorFromStore(); RouteFollowSelection.shared.placeId = nil }
        }
        .onChange(of: ConnectionWatch.shared.token) { _, _ in reloadLastRide() }
        .onChange(of: typeSize) { _, _ in reloadLastRide() }
        .onReceive(tick) { now = $0 }
        .onChange(of: AppModel.shared.scooter.connected) { _, connected in
            if connected {
                connectingSince = nil
                if preview == nil, UIApplication.shared.applicationState == .active {
                    SoundPlayer.shared.play(.connect)       // S1 with a soft tick, as the icon turns into Start (A2)
                    Haptics.soft()
                }
            }
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

    /// F-17: status pill (and any cards) on top, the Start / Connect disc centred in the free space, the Where to? row and the Load row
    /// compact at the bottom above the tab bar. At large text sizes it simply scrolls.
    private func homeScreen(_ m: HomeModel) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: DS.Space.block) {
                    topBlock(m)
                    Spacer(minLength: DS.Space.block)
                    startDisc(m)
                    Spacer(minLength: DS.Space.block)
                    bottomBlock(m)
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.bottom, DS.Space.row)
                .frame(minHeight: max(0, geo.size.height - FloatingTabBar.clearance))
            }
            .defaultScrollAnchor(UIShot.requested == "home-bottom" ? .bottom : nil)   // the ui-shot of the very bottom (B23)
        }
        .sheet(isPresented: $showWhereTo) {
            WhereToSheet(chips: shownChips, selected: selectedRoute) { id in
                pickRoute(id)
                showWhereTo = false
            }
            .glassPresentation(detents: [.medium])
        }
    }

    private func topBlock(_ m: HomeModel) -> some View {
        VStack(spacing: DS.Space.block) {
            if m.showCrashBanner { crashCard }
            if let g = gap, m.state != .riding { gapCard(g) }
            if backupBannerShown { backupCard }
            if let n = EdgeWatch.shared.expiryNotice { noticeCard(n, symbol: "clock.badge.exclamationmark") }
            if let n = EdgeWatch.shared.storageNotice { noticeCard(n, symbol: "internaldrive") }
            if m.batteryText != nil {
                NavigationLink { BatteryView() } label: { statusPill(m) }.buttonStyle(.plain)
            } else {
                statusPill(m)
            }
            if m.showLocationCard { locationCard }
            if m.state != .riding { TodayInsightSlot(preview: previewToday, live: preview == nil) }   // F-21, never during a ride (P-4)
        }
    }

    private func bottomBlock(_ m: HomeModel) -> some View {
        VStack(spacing: DS.Space.row) {
            if !(shownChips.isEmpty && shownQuick.isEmpty) && m.state != .riding { whereToRow }
            if m.state != .riding { loadRow }
        }
    }

    /// V17: the pin is not drawn while a ride is on
    private var parkedForMap: ParkedSpot? { input.rideActive || parked?.confident == false ? nil : parked }   // B34: no pin when the scooter has moved

    // MARK: Load for the next ride (F-02)

    /// Owner: Unloaded (0), 5 kg, 10 kg or Custom (a whole number, 0 to 50 kg). The segment ids:
    private static let loadNone = "none", loadFive = "5", loadTen = "10", loadCustom = "custom"
    private static let maxCustomKg = 50

    private var loadCustomLabel: String { customKg > 0 && loadSel == Self.loadCustom ? "Custom \(customKg)" : "Custom" }

    /// H4: one compact row, a load icon and Unloaded / 5 kg / 10 kg / Custom; the pill slides like the tab bar's (A5)
    private var loadRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "bag.fill").foregroundStyle(Theme.canyon).accessibilityHidden(true)
            GlassSegmented(options: [(Self.loadNone, "Unloaded"), (Self.loadFive, "5 kg"), (Self.loadTen, "10 kg"), (Self.loadCustom, loadCustomLabel)],
                           selection: Binding(get: { loadSel }, set: { _ in }), slidingPill: true, onSelect: { id in
                               if id == Self.loadCustom {
                                   kgText = customKg > 0 ? String(customKg) : ""
                                   askKg = true
                               } else {
                                   loadSel = id
                                   saveLoad()
                               }
                           })
                .accessibilityLabel("Load for the next ride")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 10)
        .alert("Custom load", isPresented: $askKg) {
            TextField("kg", text: $kgText).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                let kg = min(max(Int(kgText.trimmingCharacters(in: .whitespaces)) ?? 0, 0), Self.maxCustomKg)
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)) {
                    customKg = kg
                    loadSel = kg == 0 ? Self.loadNone : Self.loadCustom
                }
                saveLoad()
            }
        } message: {
            Text("Kilograms carried on the next ride, 0 to \(Self.maxCustomKg).")
        }
    }

    private func loadSelectorFromStore() {
        guard preview == nil else { return }
        let c = PendingLoad.get(AppModel.shared.database)
        // an older choice (Light / Heavy / Exact) shows as the number it was: 5 and 10 are their own segments, anything else is Custom
        let kg = Int(c.attachment(lightKg: RiderSettings.kg(AppModel.shared.database, .light) ?? 5,
                                  heavyKg: RiderSettings.kg(AppModel.shared.database, .heavy) ?? 15)?.kg.rounded() ?? 0)
        customKg = kg
        loadSel = kg == 0 ? Self.loadNone : (kg == 5 ? Self.loadFive : (kg == 10 ? Self.loadTen : Self.loadCustom))
        DispatchQueue.main.async { loadReady = true }
    }

    private func saveLoad() {
        guard preview == nil, loadReady else { return }
        let kg: Int
        switch loadSel {
        case Self.loadFive: kg = 5
        case Self.loadTen: kg = 10
        case Self.loadCustom: kg = customKg
        default: kg = 0
        }
        PendingLoad.set(AppModel.shared.database, kg == 0 ? .empty : LoadChoice(level: .custom, customKg: Double(kg)))
    }

    /// H3: one small pill, icon + short state + battery % (and "seen 16:33" when the scooter is not connected)
    private func statusPill(_ m: HomeModel) -> some View {
        let on = m.state == .ready || m.state == .riding
        return StatusPill(symbol: on ? "scooter" : "wifi.slash", text: HomeCopy.statusText(m), tint: on ? Theme.ok : Theme.canyon,
                          value: m.batteryText)
            .opacity(m.greyed ? 0.7 : 1)
    }

    /// The big round Start / Connect disc (amber for Connect and Try again, as before). The tap goes through `primaryTapped`, unchanged.
    private func startDisc(_ m: HomeModel) -> some View {
        let amber = m.primary == .connect || m.primary == .tryAgain
        let tint: Color = amber ? Theme.accentSoft : Theme.accent
        return VStack(spacing: 14) {
            Button {
                discTap += 1
                primaryTapped(m.primary)
            } label: {
                ZStack {
                    VStack(spacing: 8) {
                        // A2: the Connect icon breathes while connecting (no spinner) and cross-fades into Start (0.3 s)
                        Image(systemName: discSymbol(m.primary))
                            .font(.system(size: 40, weight: .semibold))
                            .symbolEffect(.pulse, options: .repeating, isActive: m.state == .connecting && !reduceMotion)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: discSymbol(m.primary))
                        Text(HomeCopy.buttonWord(m.primary, connecting: m.state == .connecting))
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                            .lineLimit(3)
                    }
                    .foregroundStyle(Theme.onAccent)   // F-15: dark text on the orange (white is only 2.3:1)
                    .padding(20)
                    .frame(width: min(discSize, Self.discCap), height: min(discSize, Self.discCap))
                    .background(GeometryReader { g in Color.clear.preference(key: DiscFrameKey.self, value: g.frame(in: .global)) })
                    .onPreferenceChange(DiscFrameKey.self) { discFrame = $0 }
                }
                .contentShape(Circle())
            }
            .buttonStyle(PillowDiscStyle(tint: tint, diameter: min(discSize, Self.discCap), forcedPress: discPressed, reduceMotion: reduceMotion))
            .disabled(!m.primaryEnabled)
            .opacity(m.primaryEnabled ? 1 : 0.6)
            .accessibilityLabel(m.primaryTitle)
        }
        .frame(maxWidth: .infinity)
    }

    /// F-17: the disc at the normal text size (was 170 pt)
    static let discBase: CGFloat = 250
    /// the largest the disc grows with Dynamic Type (it must still fit the screen width with its halo)
    static let discCap: CGFloat = 300

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
    private var shownQuick: [QuickDialItem] { previewQuick ?? quick }
    private var selectedRoute: String? { preview != nil ? previewSelected : RouteFollowSelection.shared.chosenKey }

    /// The sheet: choosing the one already chosen keeps it; nil = no destination
    private func pickRoute(_ id: String?) {
        guard preview == nil else { return }
        if let id {
            if selectedRoute != id { RouteFollowSelection.shared.choose(key: id) }
        } else {
            RouteFollowSelection.shared.choose(key: nil)
        }
    }

    /// F-29: the quick dial. Tap = choose, tap again = no destination.
    private func quickTapped(_ key: String) {
        Haptics.tick()
        guard preview == nil else { return }
        RouteFollowSelection.shared.choose(key: key)
    }

    /// F-29 (owner correction 01:35): the line under the icons always says what was chosen
    private var whereToSummary: String {
        QuickDialLoader.summary(chip: shownChips.first(where: { $0.routeId == selectedRoute }))
    }

    /// F-22 (pre-ride, silent): "Work needs about 40%, you have 45%" when the chosen route may not fit the battery
    private var preRideWarning: String? {
        guard let chip = shownChips.first(where: { $0.routeId == selectedRoute }) else { return nil }
        return DestinationRules.preRideWarning(name: chip.label, usualNeedPct: chip.usualNeedPct, batteryPct: input.connected ? input.batteryPct.map(Double.init) : nil)
    }

    private var whereToRow: some View {
        let warning = preRideWarning
        return QuickDialRow(items: shownQuick, selectedKey: selectedRoute, summary: whereToSummary, warning: warning,
                            onTap: quickTapped, onMore: { showWhereTo = true })
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassCard(radius: 26, tint: warning == nil ? nil : Theme.accent, padding: 0)
    }

    /// B35: one line, dismissable. Not modal, and it does not wait for the end of a ride (P-4 covers rides only).
    private func gapCard(_ g: UntrackedGap) -> some View {
        HStack(spacing: 10) {
            Label(OdometerGap.homeLine(km: g.km), systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button("Dismiss") {
                ConnectionWatch.dismissGaps(upTo: g.toKm)
                withAnimation(.easeInOut(duration: 0.2)) { gap = nil }
            }
            .font(.footnote.weight(.semibold))
            .frame(minHeight: DS.hit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .orange)
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
            Haptics.soft()
            if input.paired { startConnecting() } else { showOnboarding = true }
        case .tryAgain:
            Haptics.soft()
            startConnecting()
        case .startRide:
            // A3: the start sound (Kick-off, T = 0.66 s), the firm tap and the transition all begin in this same frame
            RideVoice.shared.startTapped()
            StartTransition.shared.begin(center: CGPoint(x: discFrame.midX, y: discFrame.midY), diameter: discFrame.width, reduceMotion: reduceMotion)
            withAnimation(.easeIn(duration: reduceMotion ? 0 : 0.16)) { discPressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { discPressed = false }
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
        let phone = PhoneSensors.shared.lastKnown.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        let loaded = QuickDialLoader.load(database: db, routeChips: RouteFollowLoader.chips(database: db),
                                          slots: QuickDial.slotCount(accessibilitySize: typeSize.isAccessibilitySize), from: phone)
        chips = loaded.chips
        quick = loaded.items
        if let id = RouteFollowSelection.shared.chosenKey, !chips.contains(where: { $0.routeId == id }) { RouteFollowSelection.shared.choose(key: nil) }
        parked = ParkedResolver.current(database: db, simulated: ScreenSimulator.shared.active)
        gap = ScreenSimulator.shared.active ? nil : ConnectionWatch.visibleGap(db)
        oldestRideMs = try? RideQueries(db).rides().last?.startAt
        BackupWriter.shared.runIfDue()
        EdgeWatch.shared.refresh(database: db)
        guard let r = try? RideQueries(db).rides(limit: 1).first else { return }
        lastRide = RideListItem(id: r.id, startAt: r.startAt, utcOffsetMin: r.utcOffsetMin, kind: r.kind,
                                distanceM: r.distanceM, totalS: r.totalS)
    }
}

/// "C . Pillowed" (owner): the Home disc has depth. Rest: halo ring, drop shadow, light on top, shade at the bottom. Pressed (finger down, and
/// A3's 0.16 s press-in): scale 0.97, halo tightens, shadow shrinks, light and shade swap. Always a perfect circle: every layer is a concentric
/// circle and the only transform is one uniform scale. Reduce Motion: the pressed look without the scale. The icon and word on top are
/// the button label, so A2 only cross-fades those and the disc keeps its depth.
private struct PillowDiscStyle: ButtonStyle {
    let tint: Color
    let diameter: CGFloat
    var forcedPress = false
    var reduceMotion = false
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let p = configuration.isPressed || forcedPress
        let halo: CGFloat = p ? 6 : 10
        return ZStack {
            Circle().fill(tint.opacity(p ? 0.22 : 0.16)).frame(width: diameter + halo * 2, height: diameter + halo * 2)
            Circle().fill(tint).frame(width: diameter, height: diameter)
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.6 : 0.25), radius: p ? 6 : 15, y: p ? 6 : 18)
            // inner light (top at rest) and inner shade (bottom at rest); swapped while pressed
            Circle().strokeBorder(Color.white.opacity(p ? 0.12 : 0.45), lineWidth: 20)
                .frame(width: diameter, height: diameter)
                .blur(radius: 9).offset(y: p ? -10 : 10)
                .mask(Circle().frame(width: diameter, height: diameter))
            Circle().strokeBorder(Theme.accentInk.opacity(0.35), lineWidth: 20)
                .frame(width: diameter, height: diameter)
                .blur(radius: 9).offset(y: p ? 10 : -10)
                .mask(Circle().frame(width: diameter, height: diameter))
            configuration.label
        }
        .frame(width: diameter + 24, height: diameter + 24)
        .scaleEffect(p && !reduceMotion ? 0.97 : 1)
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: p)
    }
}

private struct DiscFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// The content of the Where to? sheet (B29, a standard iOS sheet at half height): "No destination" or one of the saved routes with its
/// three chips; picking one closes the sheet (the caller does that). UI only, the selection is `RouteFollowSelection`.
private struct WhereToSheet: View {
    let chips: [WhereToChip]
    let selected: String?
    let onPick: (String?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.row) {
                Text("Where to?").font(.headline).fontDesign(.rounded).padding(.top, 22).padding(.bottom, 4)
                row("No destination", chip: nil, on: selected == nil) { onPick(nil) }
                ForEach(chips, id: \.routeId) { c in
                    row(c.label, chip: c, on: c.routeId == selected) { onPick(c.routeId) }
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, DS.Space.block)
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
        guard name == "home-whereto" || name == "home-whereto-sheet" || name == "home-quick" else { return nil }
        var work = WhereToChip(routeId: "a", label: "Work", detail: "Work")
        work.timeText = "13 min"; work.arriveText = "8:56"; work.usedText = "11%"
        var home = WhereToChip(routeId: "b", label: "Home", detail: "Home")
        home.timeText = "14 min"; home.arriveText = "9:02"; home.usedText = "12%"
        var maya = WhereToChip(routeId: "place:m", label: "Maya's house", detail: "Maya's house")
        maya.timeText = "12 min"; maya.arriveText = "9:00"; maya.usedText = "9%"; maya.usualNeedPct = 9
        return [work, home, maya]
    }

    /// F-29: made-up quick-dial buttons (a symbol, a symbol, typed letters)
    static func quick(_ name: String) -> [QuickDialItem]? {
        guard name == "home-whereto" || name == "home-whereto-sheet" || name == "home-quick" else { return nil }
        return [QuickDialItem(id: "b", name: "Home", icon: .symbol("house"), key: "b"),
                QuickDialItem(id: "a", name: "Work", icon: .symbol("building.2"), key: "a"),
                QuickDialItem(id: "m", name: "Maya's house", icon: .letters("M"), key: "place:m")]
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
        case "home-ready", "home-parked", "home-whereto", "home-whereto-sheet", "home-quick":
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

/// The short Home words (H2, H3), kept apart so the automatic checks u64 / u69 can test them.
enum HomeCopy {
    /// B29: the closed Where to? row: "Where to? · Work", or "Where to? · No destination"
    static func whereToLine(label: String?) -> String {
        "Where to? \u{00B7} \(label ?? "No destination")"
    }

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
