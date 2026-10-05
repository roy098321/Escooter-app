import CorckieCore
import SwiftUI

/// M1-11 Home (IA: Home tab). States per STATES S1 / S2: first use and not connected show the amber
/// "Connect your scooter" (never Start ride); connected shows the status card + Start ride; a failed connect
/// says "Can't find the scooter" after 30 s with Try again; a ride in progress says so. The rules live in
/// `HomeLogic` (CorckieCore, unit tested); this view only shows the model.
struct HomeView: View {
    /// ui-shots: a made-up input instead of the real app state
    var preview: HomeInput?
    /// ui-shots: made-up Where to? chips and the chosen one
    var previewChips: [WhereToChip]?
    var previewSelected: String?

    @State private var chips: [WhereToChip] = []
    @State private var now = Date()
    @State private var connectingSince: Date?
    @State private var showOnboarding = false
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
                .navigationTitle("Home")
                .screen("Home")
                .toolbar {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
        }
        .onAppear(perform: reloadLastRide)
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
    }

    private func content(_ m: HomeModel) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                if m.showCrashBanner { crashCard }
                if backupBannerShown { backupCard }
                if m.batteryText != nil {
                    NavigationLink { BatteryView() } label: { statusCard(m) }.buttonStyle(.plain)
                } else {
                    statusCard(m)
                }
                primaryButton(m)
                if m.state != .riding { whereTo }
                if m.showLocationCard { locationCard }
                if let text = newestInsight, m.state != .riding {
                    HStack(alignment: .top) {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                        Text(text).font(.subheadline)
                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                if let text = m.lastRideText {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        Text(text).font(.subheadline)
                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding()
        }
    }

    private func statusCard(_ m: HomeModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: m.state == .ready || m.state == .riding ? "scooter" : "wifi.slash")
                Text(m.title).font(.headline)
                Spacer()
                if let battery = m.batteryText {
                    Text(battery).font(.title2.bold().monospacedDigit())
                }
            }
            Text(m.detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .opacity(m.greyed ? 0.65 : 1)
        .accessibilityElement(children: .combine)
    }

    private func primaryButton(_ m: HomeModel) -> some View {
        Button {
            primaryTapped(m.primary)
        } label: {
            Text(m.primaryTitle)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(m.primary == .connect || m.primary == .tryAgain ? .orange : .accentColor)
        .disabled(!m.primaryEnabled)
    }

    // MARK: Where to? (M2-06): one chip per saved route; hidden until a route exists (S2)

    private var shownChips: [WhereToChip] { previewChips ?? chips }
    private var selectedRoute: String? { preview != nil ? previewSelected : RouteFollowSelection.shared.routeId }

    @ViewBuilder private var whereTo: some View {
        let list = shownChips
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Where to?").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(list, id: \.routeId) { c in
                            let on = selectedRoute == c.routeId
                            Button {
                                if preview == nil { RouteFollowSelection.shared.toggle(c.routeId) }
                            } label: {
                                Text(c.label)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(on ? Color.accentColor : Color(.tertiarySystemBackground), in: Capsule())
                                    .foregroundStyle(on ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                if let sel = list.first(where: { $0.routeId == selectedRoute }) {
                    Text(sel.detail).font(.subheadline).foregroundStyle(.secondary)
                    Text("The arrival time shows on the ride screen.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
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
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
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
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
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
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
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
        guard let r = try? RideQueries(db).rides(limit: 1).first else { return }
        lastRide = RideListItem(id: r.id, startAt: r.startAt, utcOffsetMin: r.utcOffsetMin, kind: r.kind,
                                distanceM: r.distanceM, totalS: r.totalS)
    }
}

/// Made-up Home states for the CI ui-shots (`-uiShot home-first` and so on).
enum HomePreview {
    /// M2-06: made-up chips (no real place names)
    static func chips(_ name: String) -> [WhereToChip]? {
        guard name == "home-whereto" else { return nil }
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
        case "home-ready", "home-whereto":
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
