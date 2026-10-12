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

    @State private var chips: [WhereToChip] = []
    @State private var now = Date()
    @State private var connectingSince: Date?
    @State private var showOnboarding = false
    @State private var showWhereTo = false
    @State private var crashDismissed = false
    @State private var lastRide: RideListItem?
    @State private var oldestRideMs: Int64?
    /// M4-10: the newest insight (a line under the last ride)
    @State private var newestInsight: String?
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
            content(HomeLogic.model(input))
                .background { MapBackdrop().ignoresSafeArea() }
                .navigationTitle("Home")
                .screen("Home")
                .toolbar {
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
            reloadLastRide()
            if previewSheet { showWhereTo = true }
        }
        .onChange(of: ScreenSimulator.shared.active) { _, _ in lastRide = nil; reloadLastRide() }
        .onChange(of: RecorderService.shared.summaryRideId) { _, _ in reloadLastRide() }
        .onReceive(tick) { now = $0 }
        .onChange(of: AppModel.shared.scooter.connected) { _, connected in
            if connected { connectingSince = nil }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(onFinish: { _ in
                showOnboarding = false
                reloadLastRide()
            })
            .v1Label()
        }
        .sheet(isPresented: $showWhereTo) {
            WhereToSheet(chips: shownChips, selected: selectedRoute, onPick: pickRoute)
                .glassPresentation(detents: [.medium])
                .v1Label()
        }
    }

    private func content(_ m: HomeModel) -> some View {
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
                if m.state != .riding { whereTo }
                if m.showLocationCard { locationCard }
                startDisc(m)
                if let text = newestInsight, m.state != .riding {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                        Text(text).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .glassCard()
                }
                if let text = m.lastRideText {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text(text).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .glassCard()
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, DS.Space.block)
        }
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
        .glassCard(radius: DS.Radius.hero, padding: 18)
        .opacity(m.greyed ? 0.7 : 1)
        .accessibilityElement(children: .combine)
    }

    /// The 170 pt round Start / Connect disc (amber for Connect and Try again, as before). The tap goes through `primaryTapped`, unchanged.
    private func startDisc(_ m: HomeModel) -> some View {
        let amber = m.primary == .connect || m.primary == .tryAgain
        let tint: Color = amber ? .orange : .accentColor
        return VStack(spacing: 14) {
            Button {
                primaryTapped(m.primary)
            } label: {
                ZStack {
                    Circle().fill(tint.opacity(0.2)).frame(width: 194, height: 194)
                    VStack(spacing: 8) {
                        if m.state == .connecting {
                            ProgressView().controlSize(.large).tint(.white)
                        } else {
                            Image(systemName: discSymbol(m.primary)).font(.system(size: 40, weight: .semibold))
                        }
                        Text(m.primaryTitle)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                            .lineLimit(3)
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                    .frame(width: 170, height: 170)
                    .background(tint, in: Circle())
                    .shadow(color: tint.opacity(0.35), radius: 14, y: 6)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!m.primaryEnabled)
            .opacity(m.primaryEnabled ? 1 : 0.6)
            .accessibilityLabel(m.primaryTitle)
            if m.state == .ready {
                Text("Rides also start on their own as soon as the wheel turns.")
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

    @ViewBuilder private var whereTo: some View {
        let list = shownChips
        if !list.isEmpty {
            let chosen = list.first(where: { $0.routeId == selectedRoute })
            Button { showWhereTo = true } label: {
                HStack {
                    Text("Where to?").font(.body)
                    Spacer(minLength: 8)
                    Text(chosen?.label ?? "No destination").foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(minHeight: 28)
                .glassCard()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Where to?")
            .accessibilityValue(chosen?.label ?? "No destination")
            .accessibilityAddTraits(.isButton)
            if let chosen {
                Text(chosen.detail)
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
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
        newestInsight = ((try? InsightQueries(db).recent(limit: 1)) ?? []).first?.text
        BackupWriter.shared.runIfDue()
        EdgeWatch.shared.refresh(database: db)
        guard let r = try? RideQueries(db).rides(limit: 1).first else { return }
        lastRide = RideListItem(id: r.id, startAt: r.startAt, utcOffsetMin: r.utcOffsetMin, kind: r.kind,
                                distanceM: r.distanceM, totalS: r.totalS)
    }
}

/// The Where to? sheet: "No destination" or one of the saved routes; picking one closes it. UI only, the selection is `RouteFollowSelection`.
private struct WhereToSheet: View {
    let chips: [WhereToChip]
    let selected: String?
    let onPick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.row) {
                Text("Where to?")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 20)
                    .padding(.bottom, 4)
                row("No destination", detail: nil, on: selected == nil) { onPick(nil) }
                ForEach(chips, id: \.routeId) { c in
                    row(c.label, detail: c.routeId == selected ? c.detail : nil, on: c.routeId == selected) { onPick(c.routeId) }
                }
                if selected != nil {
                    Text("The arrival time shows on the ride screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, 24)
        }
    }

    private func row(_ title: String, detail: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(on ? .semibold : .regular))
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
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
