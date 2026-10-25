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
    /// P6-5: made-up Where to? rows (icon, colour, pin) for the ui-shots
    var previewRows: [WhereToRow]?
    /// F-31: a made-up running charge timer for the ui-shot
    var previewCharge: ChargeSession?

    /// F-17: the disc is 250 pt at normal text size and grows with Dynamic Type (capped at 300 pt)
    @ScaledMetric(relativeTo: .title3) private var discSize: CGFloat = HomeView.discBase
    @State private var chips: [WhereToChip] = []
    /// F-29: the round buttons of the quick dial
    @State private var quick: [QuickDialItem] = []
    /// P6-5: the rows of the Where to? sheet (icon, colour, pin, time or the reason there is none)
    @State private var rows: [WhereToRow] = []
    /// B46: the line shown under the quick dial for a moment after a tap on the place the phone is in
    @State private var hereLine: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sunlight) private var sunlight
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
                         batteryPct: AppModel.shared.settledBatteryPct ?? (simulated ? RecorderService.shared.live?.batteryPct : nil),
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
                .background { MapBackdrop(map: true, parked: nil, parkedPreview: nil)   // B60: no parked pin on Home's map background.ignoresSafeArea() }
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
        .onChange(of: showWhereTo) { _, open in if open { reloadLastRide() } }   // B58: fresh times when the sheet opens
        .sheet(isPresented: $showWhereTo) {
            WhereToSheet(rows: shownRows, selected: selectedRoute, editable: preview == nil, onPick: { id in
                pickRoute(id)
                showWhereTo = false
            }, onPins: { pins in
                savePins(pins)
            })
            .glassPresentation(detents: [.medium, .large])
        }
    }

    private func topBlock(_ m: HomeModel) -> some View {
        VStack(spacing: DS.Space.block) {
            if m.showCrashBanner { crashCard }
            if let g = gap, m.state != .riding { gapCard(g) }
            if backupBannerShown { backupCard }
            if let n = EdgeWatch.shared.expiryNotice { noticeCard(n, symbol: "clock.badge.exclamationmark") }
            if let n = EdgeWatch.shared.storageNotice { noticeCard(n, symbol: "internaldrive") }
            if let cs = previewCharge ?? (preview == nil && m.state != .riding ? ChargeTimer.shared.session : nil) {
                // F-31: while charging the status pill is the charge line
                NavigationLink { BatteryView() } label: {
                    ChargeStatusLine(session: cs, nowMs: previewCharge != nil ? ChargePreview.nowMs : ChargeTimer.shared.nowMs, utcOffsetMin: previewCharge != nil ? 0 : ChargeTimer.shared.utcOffsetMin)
                }.buttonStyle(.plain)
            } else if m.batteryText != nil {
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
            if m.state != .riding, preview == nil, let trip = TripService.shared.offer { continueRow(trip) }
            // B55: the quick dial is never hidden (No destination and the dots are always there), even when the places could not be read
            if m.state != .riding { whereToRow.onAppear { if preview == nil, quick.isEmpty { reloadLastRide() } } }
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
                        // A2: the Connect icon breathes while connecting (no spinner) and cross-fades into Start (0.3 s).
                        // P6-5: with a destination chosen the Start disc shows that place's icon instead of the generic start glyph.
                        ZStack {
                            if let icon = discDestinationIcon(m) {
                                destinationGlyph(icon)
                            } else {
                                Image(systemName: discSymbol(m.primary))
                                    .font(.system(size: 40, weight: .semibold))
                                    .symbolEffect(.pulse, options: .repeating, isActive: m.state == .connecting && !reduceMotion)
                            }
                        }
                        .frame(height: 48)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: discSymbol(m.primary) + (discDestinationIcon(m)?.code ?? ""))
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
        .background { discGlow }
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

    /// P6-5: the chosen place's icon when the scooter is connected and Start shows (a route with no named place gives none)
    private func discDestinationIcon(_ m: HomeModel) -> PlaceIcon? {
        guard m.primary == .startRide, let key = selectedRoute else { return nil }
        return shownRows.first(where: { $0.key == key && $0.placeId != nil })?.icon
    }

    @ViewBuilder private func destinationGlyph(_ icon: PlaceIcon) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: UIImage(systemName: name) != nil ? name : PlaceIcon.fallbackSymbol)
                .font(.system(size: 40, weight: .semibold))
                .transition(.opacity)
        case .letters(let text):
            Text(text)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .transition(.opacity)
        }
    }

    /// B48: in light mode a soft warm sand glow sits behind the Connect / Start disc (the accent at a low alpha); dark mode is unchanged
    @ViewBuilder private var discGlow: some View {
        if scheme == .light && !sunlight {
            RadialGradient(colors: [Theme.accent.opacity(0.30), Theme.accent.opacity(0.10), .clear], center: .center, startRadius: 40, endRadius: 270)
                .frame(width: 560, height: 560)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Where to? (M2-06): a row that opens a sheet with one choice per saved route; hidden until a route exists (S2)

    private var shownChips: [WhereToChip] { previewChips ?? chips }
    private var shownQuick: [QuickDialItem] { previewQuick ?? quick }
    private var shownRows: [WhereToRow] { previewRows ?? rows }
    private var selectedRoute: String? { preview != nil ? previewSelected : RouteFollowSelection.shared.chosenKey }

    /// The sheet: choosing the one already chosen keeps it; nil = no destination. The place the phone is in cannot be chosen (B46).
    private func pickRoute(_ id: String?) {
        if let id, let chip = shownChips.first(where: { $0.routeId == id }), chip.here {
            Haptics.soft()
            flashHere(chip.label)
            return
        }
        Haptics.tick()
        guard preview == nil else { return }
        if let id {
            if selectedRoute != id { RouteFollowSelection.shared.choose(key: id) }
        } else {
            RouteFollowSelection.shared.choose(key: nil)
        }
        TripService.shared.picked(key: RouteFollowSelection.shared.chosenKey)      // F-39: another destination closes the open trip
    }

    /// F-29: the quick dial. Tap = choose, tap again = no destination. A light tick on every tap; the place the phone is in gives a soft
    /// tick and the line says "You're at Home" (B46).
    private func quickTapped(_ item: QuickDialItem) {
        if item.here {
            Haptics.soft()
            flashHere(item.name)
            return
        }
        Haptics.tick()
        guard preview == nil else { return }
        RouteFollowSelection.shared.choose(key: item.key)
        TripService.shared.picked(key: RouteFollowSelection.shared.chosenKey)      // F-39
    }

    /// the first slot of the quick dial: no destination
    private func clearTapped() {
        Haptics.tick()
        guard preview == nil else { return }
        RouteFollowSelection.shared.choose(key: nil)
        TripService.shared.picked(key: nil)                                         // F-39: No destination closes the open trip
    }

    private func flashHere(_ name: String) {
        withAnimation(.easeInOut(duration: 0.2)) { hereLine = PlaceHere.tapLine(name: name) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation(.easeInOut(duration: 0.2)) { hereLine = nil } }
    }

    /// P6-5: the sheet's pin changes land in the same settings as the place screen's "Show on Home", and show on Home at once
    private func savePins(_ pins: [String: Int]) {
        guard preview == nil, let db = AppModel.shared.displayDatabase else { return }
        try? QuickDialLoader.writePins(pins, database: db)
        reloadLastRide()
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

    /// F-39 flaw 1: the trip did not arrive: "↻ Continue to Uni" first, one tap sets the destination again (ignoring it keeps it open)
    private func continueRow(_ trip: TripRules.OpenTrip) -> some View {
        Button {
            Haptics.tick()
            TripService.shared.continueTapped()
        } label: {
            HStack(spacing: 10) {
                Text(TripRules.continueText(trip)).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if RouteFollowSelection.shared.chosenKey == QuickDialLoader.placePrefix + trip.placeId {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accentInk)
                }
            }
            .foregroundStyle(Theme.accentInk)
            .padding(.horizontal, 16)
            .frame(minHeight: DS.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(radius: 22, padding: 0)
        .accessibilityLabel("Continue to \(trip.placeName)")
    }

    private var whereToRow: some View {
        let warning = hereLine == nil ? preRideWarning : nil
        return QuickDialRow(items: shownQuick, selectedKey: selectedRoute, summary: hereLine ?? whereToSummary, warning: warning,
                            onTap: quickTapped, onClear: clearTapped, onMore: { showWhereTo = true })
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
        guard preview == nil else { return }
        guard let db = AppModel.shared.displayDatabase else {
            Log.info(source: "home", "B55: quick dial not loaded: the database is not open yet (the row shows No destination and the list button)")
            return
        }
        let phone = PhoneSensors.shared.lastKnown.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        let loaded = QuickDialLoader.load(database: db, routeChips: RouteFollowLoader.chips(database: db),
                                          slots: QuickDial.slotCount(accessibilitySize: typeSize.isAccessibilitySize), from: phone)
        chips = loaded.chips
        quick = loaded.items
        rows = loaded.rows
        if let failure = QuickDialLoader.lastFailure { Log.error(source: "home", "B55: quick dial load failed: \(failure)") }
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

/// The content of the Where to? sheet (B29, a standard iOS sheet). P6-5: compact one-line rows, the place's icon in its colour, the name, and on
/// the right "17 min \u{00B7} arrive 17:11" (or why there is no time: "no rides there yet", "You are here"). Each place has a pin ("On Home", at most
/// 3; the 4th asks which to replace); Edit drags the pinned ones into order. Picking a row closes the sheet (the caller does that). UI only; the
/// selection is `RouteFollowSelection` and the pins are the same settings as the place screen's "Show on Home".
private struct WhereToSheet: View {
    let rows: [WhereToRow]
    let selected: String?
    var editable = true
    let onPick: (String?) -> Void
    let onPins: ([String: Int]) -> Void

    @State private var editing = false
    @State private var replacing: WhereToRow?

    private var pins: [String: Int] {
        var out: [String: Int] = [:]
        for r in rows { if let id = r.placeId, let p = r.pin { out[id] = p } }
        return out
    }
    private var pinnedRows: [WhereToRow] { rows.filter { $0.pin != nil }.sorted { ($0.pin ?? 0) < ($1.pin ?? 0) } }
    private var canEdit: Bool { editable && rows.contains { $0.placeId != nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Where to?").font(.headline).fontDesign(.rounded)
                Spacer()
                if canEdit {
                    Button(editing ? "Done" : "Edit") { Haptics.tick(); withAnimation(.easeInOut(duration: 0.2)) { editing.toggle() } }
                        .font(.body.weight(.semibold))
                        .frame(minHeight: DS.hit)
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, 14)
            if editing { editList } else { pickList }
        }
        .confirmationDialog("Replace which?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }), titleVisibility: .visible) {
            if let new = replacing?.placeId {
                ForEach(pinnedRows, id: \.key) { old in
                    if let oldId = old.placeId {
                        Button(old.name) { onPins(QuickDialSlot.replace(oldId, with: new, in: pins)) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var pickList: some View {
        ScrollView {
            VStack(spacing: 6) {
                Button { onPick(nil) } label: {
                    HStack(spacing: 10) {
                        FreeRideIcon(size: 34, selected: selected == nil)
                        Text(QuickDialSlot.freeRideName).font(.body.weight(selected == nil ? .semibold : .regular))
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .glassCard(radius: 16, padding: 0)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == nil ? .isSelected : [])
                ForEach(rows) { r in
                    HStack(spacing: 6) {
                        Button { onPick(r.key) } label: { rowLabel(r) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(r.key == selected ? .isSelected : [])
                        if editable, r.placeId != nil { pinButton(r) }
                    }
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, 6)
            .padding(.bottom, DS.Space.block)
        }
    }

    private var editList: some View {
        List {
            Section {
                ForEach(pinnedRows) { r in
                    HStack(spacing: 10) {
                        PlaceIconView(icon: r.icon, size: 34, selected: true, colourId: r.colourId)
                        Text(r.name).lineLimit(1)
                        Spacer(minLength: 8)
                        pinButton(r)
                    }
                }
                .onMove { from, to in
                    var ids = pinnedRows.compactMap(\.placeId)
                    ids.move(fromOffsets: from, toOffset: to)
                    Haptics.tick()
                    onPins(QuickDialSlot.reordered(ids))
                }
            } header: {
                Text("On Home \u{00B7} drag to reorder")
            }
            Section {
                ForEach(rows.filter { $0.pin == nil && $0.placeId != nil }) { r in
                    HStack(spacing: 10) {
                        PlaceIconView(icon: r.icon, size: 34, selected: false, colourId: r.colourId)
                        Text(r.name).lineLimit(1)
                        Spacer(minLength: 8)
                        pinButton(r)
                    }
                }
            } header: {
                Text("Other places")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    private func rowLabel(_ r: WhereToRow) -> some View {
        HStack(spacing: 10) {
            PlaceIconView(icon: r.icon, size: 34, selected: r.key == selected, colourId: r.placeId == nil ? nil : r.colourId, here: r.here)
            Text(r.name).font(.body.weight(r.key == selected ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 6)
            // B58: the arrival clock moves on every minute while the sheet is open
            TimelineView(.everyMinute) { tl in
                Text(trailing(r, at: tl.date))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .glassCard(radius: 16, padding: 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.name), \(trailing(r))")
    }

    /// "17 mins \u{2022} 9% battery \u{2022} arrive 17:11" (note 14: time and battery, the battery only with a usual need), the reason there is
    /// no time, or "You are here". B58: the arrival is leaving now (`at`), not the clock of the moment the list was loaded.
    private func trailing(_ r: WhereToRow, at now: Date = Date()) -> String {
        if r.here { return PlaceHere.hereWord }
        if let t = r.timeText {
            let a = r.timeS.map { WhereTo.arriveText(timeS: $0, nowMs: Int64(now.timeIntervalSince1970 * 1000),
                                                     utcOffsetMin: TimeZone.current.secondsFromGMT(for: now) / 60) } ?? r.arriveText
            let minutes = Int(t.split(separator: " ").first ?? "")
            var parts = minutes.map { QuickDial.estimateParts(minutes: $0, needPct: r.needPct) } ?? [t]
            if let a { parts.append("arrive \(a)") }
            return parts.joined(separator: QuickDial.estimateSeparator)
        }
        return r.note ?? ""
    }

    private func pinButton(_ r: WhereToRow) -> some View {
        let on = r.pin != nil
        return Button { togglePin(r) } label: {
            Image(systemName: on ? "pin.fill" : "pin")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on ? Theme.accentInk : Color.secondary)
                .frame(width: DS.hit, height: DS.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("On Home")
        .accessibilityValue(on ? "on" : "off")
    }

    private func togglePin(_ r: WhereToRow) {
        guard let id = r.placeId else { return }
        Haptics.tick()
        if pins[id] != nil {
            onPins(QuickDialSlot.unpin(id, in: pins))
        } else {
            switch QuickDialSlot.pin(id, in: pins) {
            case .pinned(let next): onPins(next)
            case .needsReplace: replacing = r
            }
        }
    }
}

/// Made-up Home states for the CI ui-shots (`-uiShot home-first` and so on).
enum HomePreview {
    private static func hasQuick(_ name: String) -> Bool { name == "home-whereto" || name == "home-whereto-sheet" || name == "home-quick" }

    /// M2-06 + P6-5: made-up chips (no real place names): two with a time, one the phone is in (Home), one with no rides (B44), one with one ride (B45)
    static func chips(_ name: String) -> [WhereToChip]? {
        guard hasQuick(name) else { return nil }
        var work = WhereToChip(routeId: "a", label: "Work", detail: "Work")
        work.timeText = "13 min"; work.arriveText = "8:56"; work.usedText = "11%"; work.usualNeedPct = 11; work.timeS = 780
        var home = WhereToChip(routeId: "b", label: "Home", detail: "Home")
        home.timeText = "14 min"; home.arriveText = "9:02"; home.usedText = "12%"; home.here = true
        var maya = WhereToChip(routeId: "place:m", label: "Maya's house", detail: "Maya's house")
        maya.timeText = "12 min"; maya.arriveText = "9:00"; maya.usedText = "9%"; maya.usualNeedPct = 9; maya.timeS = 720
        var gran = WhereToChip(routeId: "place:g", label: "Grandma", detail: "Grandma")
        gran.note = "no rides there yet"
        var old = WhereToChip(routeId: "place:o", label: "Old workplace", detail: "Old workplace")
        old.note = "1 ride there \u{00B7} estimate after 2"
        return [work, home, maya, gran, old]
    }

    /// F-29: made-up quick-dial buttons (a symbol, a symbol, typed letters), each in its place colour; Home is the place the phone is in
    static func quick(_ name: String) -> [QuickDialItem]? {
        guard hasQuick(name) else { return nil }
        return [QuickDialItem(id: "b", name: "Home", icon: .symbol("house"), key: "b", colourId: "green", here: true),
                QuickDialItem(id: "a", name: "Work", icon: .symbol("building.2"), key: "a", colourId: "blue"),
                QuickDialItem(id: "m", name: "Maya's house", icon: .letters("M"), key: "place:m", colourId: "pink")]
    }

    /// P6-5: made-up rows of the Where to? sheet
    static func rows(_ name: String) -> [WhereToRow]? {
        guard let chips = chips(name) else { return nil }
        let looks: [String: (PlaceIcon, String, Int?)] = [
            "a": (.symbol("building.2"), "blue", 2), "b": (.symbol("house"), "green", 1), "place:m": (.letters("M"), "pink", 3),
            "place:g": (.symbol("figure.and.child.holdinghands"), "yellow", nil), "place:o": (.symbol("building.columns"), "vermillion", nil)
        ]
        return chips.map { c in
            let look = looks[c.routeId] ?? (.letters("?"), "orange", nil)
            return WhereToRow(key: c.routeId, name: c.label, icon: look.0, colourId: look.1, placeId: c.routeId, here: c.here, pin: look.2,
                              timeText: c.timeText, arriveText: c.arriveText, note: c.note, timeS: c.timeS, needPct: c.usualNeedPct)
        }
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
