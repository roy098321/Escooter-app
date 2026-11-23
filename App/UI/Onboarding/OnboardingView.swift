import CorckieCore
import CoreMotion
import SwiftUI
import UserNotifications

/// M1-11 onboarding (C27, lean): three presses, no tour. 1 Connect (the found scooter) · 2 Allow (location Always +
/// motion, iOS asks) · 3 Allow / Not now (notifications with sound). Then Home. Bluetooth is asked when the
/// scooter link starts at step 1. The flow's rules are `OnboardingFlow` in CorckieCore (unit tested).
struct OnboardingView: View {
    private let previewFound: Bool
    private let onFinish: (OnboardingFlow) -> Void
    @State private var flow: OnboardingFlow
    @State private var busy = false
    @State private var alertsOpen = false
    @State private var showRestore = false      // D2: "Have a backup? Restore" (a new phone or a reinstall)
    /// A-06: the welcome screen (and optional tour) first, on the first launch only
    @State private var showWelcome: Bool
    /// A-07: when the search for the scooter started (the 30 s "Can't find it" rule, as on Home)
    @State private var searchingSince: Date?
    @State private var now = Date()
    @State private var whichOpen = false

    init(startAt: OnboardingFlow.Step = .connect, previewFound: Bool = false, welcome: Bool = false, onFinish: @escaping (OnboardingFlow) -> Void) {
        self.previewFound = previewFound
        self.onFinish = onFinish
        _showWelcome = State(initialValue: welcome)
        _flow = State(initialValue: OnboardingFlow(scooterFound: previewFound, startAt: startAt))
    }

    var body: some View {
        if showWelcome {
            WelcomeView {
                withAnimation(.easeOut(duration: 0.25)) { showWelcome = false }
            }
        } else {
            steps
        }
    }

    private var steps: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            heroIcon
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                stepDots
                switch flow.step {
                case .connect: connectStep
                case .location: locationStep
                case .notifications: notificationsStep
                case .done: ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .glassCard(radius: DS.Radius.hero, padding: 20)
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { MapBackdrop().ignoresSafeArea() }
        .onAppear {
            guard !previewFound else { return }
            // D2 3a: the line on screen is read before the iPhone's Bluetooth pop-up covers it
            AppModel.shared.scooter.setupShown(true)      // B102: only setup connects a new scooter (also after Set up later)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppModel.shared.scooter.start() }
            searchingSince = Date()
            PermissionsCheck.shared.refresh()
            refreshFound()
        }
        // B102: a 1 s loop tied to this screen, not a Timer publisher made in init: Home redraws every second and
        // re-made the publisher each time, so the tick could never fire and setup kept "searching" while connected
        .task {
            while !Task.isCancelled {
                now = Date()
                refreshFound()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onChange(of: AppModel.shared.scooter.connected) { _, _ in refreshFound() }   // B102: found the moment it connects
        .onDisappear { if !previewFound { AppModel.shared.scooter.setupShown(false) } }
    }

    // MARK: Steps

    /// the big round icon above the card
    private var heroIcon: some View {
        let symbol: String
        var tint = Theme.accent
        switch flow.step {
        case .connect:
            symbol = flow.scooterFound ? "checkmark" : "scooter"
            if flow.scooterFound { tint = .green }
        case .location: symbol = "location.fill"
        case .notifications: symbol = "bell.badge.fill"
        case .done: symbol = "checkmark"
        }
        return Image(systemName: symbol)
            .scaledFont(56, weight: .semibold)      // A-26: grows with large text
            .foregroundStyle(tint)
            .frame(width: 140, height: 140)
            .glassCard(radius: 70, padding: 0)
            .accessibilityHidden(true)
    }

    /// O1: three dots instead of "Step 1 of 3"
    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(1...OnboardingFlow.stepCount, id: \.self) { i in
                Circle()
                    .fill(i <= flow.step.rawValue ? Theme.accent : Theme.chip)
                    .frame(width: 9, height: 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(flow.step == .done ? "Done" : "Step \(flow.stepText)")
    }

    private var connectStep: some View {
        VStack(spacing: 14) {
            Text("Connect your scooter").font(.title2.bold()).multilineTextAlignment(.center)
            if let problem = AppModel.shared.scooter.bluetoothProblem {
                BluetoothProblemView(problem: problem)      // D2 3b
            } else if flow.scooterFound {
                let link = AppModel.shared.scooter
                Label("Found", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                if link.connected {
                    // D2 1a: which scooter it is, so the rider can match the km with the dashboard
                    Text(KnownScooters.foundText(model: link.foundModel ?? "Scooter", odometerKm: link.frame?.odometerKm,
                                                 batteryPct: link.frame?.batteryPct))
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                    // B102: a data layout the app can't read yet: it connects and keeps the raw data, no numbers shown
                    Text(link.numbersUnsupported ? "Connected \u{00B7} numbers not supported yet"
                         : link.frame?.odometerKm != nil ? "Check that your dashboard shows the same km." : "Connected")   // B102: the G500 sends no km
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if NewRider.cantFind(searchingSinceS: searchingSince?.timeIntervalSince1970, nowS: now.timeIntervalSince1970,
                                        found: flow.scooterFound) {
                cantFindBlock      // A-07: after 30 s, what to try and which scooters work
            } else {
                VStack(spacing: 8) {
                    Text("Switch it on, keep it close.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text("Your iPhone will ask for Bluetooth: tap Allow.")      // D2 3a
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
            }
            bigButton("Connect", enabled: flow.canConnect) {
                if flow.press(.connect) { AppModel.shared.scooter.confirmPairing() }     // D2 1b: saved only now
            }
            Button("Set up later") { skip() }
                .font(.subheadline)
                .frame(minHeight: DS.hit)
            Button("Have a backup? Restore") { showRestore = true }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .sheet(isPresented: $showRestore) { NavigationStack { RestoreView() } }
        }
    }

    /// A-07: the same 30 s rule as Home, then tips and "Which scooters work?"; the search keeps running underneath
    private var cantFindBlock: some View {
        VStack(spacing: 8) {
            Label(NewRider.cantFindTitle, systemImage: "magnifyingglass")
                .font(.headline)
                .foregroundStyle(Theme.accentInk)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(NewRider.cantFindTips, id: \.self) { tip in
                    Text("\u{2022} " + tip).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(whichOpen ? "Hide" : "Which scooters work?") { withAnimation { whichOpen.toggle() } }
                .font(.footnote.weight(.semibold))
            if whichOpen {
                Text(NewRider.supportedLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var locationStep: some View {
        VStack(spacing: 14) {
            Text("Let rides start on their own").font(.title2.bold()).multilineTextAlignment(.center)
            Text(NewRider.locationLine)      // A-08: iOS asks for Always later, not right away
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Label(NewRider.safetyLine, systemImage: "eye")      // A-21: once, calm
                .font(.footnote)
                .foregroundStyle(.secondary)
            bigButton(busy ? "Asking\u{2026}" : "Allow", enabled: !busy) { allowLocation() }
            Button("Not now") { finish(.notNow) }
                .font(.subheadline)
                .frame(minHeight: DS.hit)
                .disabled(busy)
        }
    }

    private var notificationsStep: some View {
        VStack(spacing: 14) {
            Text("Scooter alerts").font(.title2.bold()).multilineTextAlignment(.center)
            Text(NewRider.alertsLine)      // A-09: plain words
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(alertsOpen ? "Hide" : "All the alerts") { alertsOpen.toggle() }      // D2 4b: optional, behind a tap
                .font(.footnote.weight(.semibold))
            if alertsOpen {
                Text(NotifyKind.allCases.map(\.title).joined(separator: "\n") + "\n" + NotifyKind.alwaysOn + "\nEach one has its own switch in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            bigButton("Allow", enabled: !busy) { allowNotifications() }
            Button("Not now") { finish(.notNow) }
                .font(.subheadline)
                .frame(minHeight: DS.hit)
                .disabled(busy)
        }
    }

    private func bigButton(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            if flow.isDone { complete() }
        } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
    }

    // MARK: Actions

    private func refreshFound() {
        guard !previewFound else { return }
        let scooter = AppModel.shared.scooter
        flow.setScooterFound(scooter.connected || scooter.hasKnownScooter)
    }

    private func allowLocation() {
        guard !busy else { return }
        busy = true
        let perms = PermissionsCheck.shared
        Task { @MainActor in
            perms.askLocationWhileUsing()
            await waitUntil(seconds: 90) { perms.locationStatus != .notDetermined }
            perms.askLocationAlwaysQuietly()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            perms.askMotion()
            await waitUntil(seconds: 60) { CMMotionActivityManager.authorizationStatus() != .notDetermined }
            busy = false
            finish(.allow)
        }
    }

    private func allowNotifications() {
        guard !busy else { return }
        busy = true
        UNUserNotificationCenter.current().requestAuthorization(options: PermissionsCheck.notificationOptions) { _, _ in
            DispatchQueue.main.async {
                PermissionsCheck.shared.refresh()
                busy = false
                finish(.allow)
            }
        }
    }

    private func finish(_ p: OnboardingFlow.Press) {
        flow.press(p)
        if flow.isDone { complete() }
    }

    private func skip() {
        AppModel.shared.scooter.cancelPairing()     // D2 1b
        flow.skipForNow()
        complete()
    }

    private func complete() {
        OnboardingState.done = true
        // A-03: outside data waited for onboarding; it may start now that location was asked
        OutsideDataService.shared.refresh(database: AppModel.shared.database, reason: "onboarding done")
        // N5-2 / T8: the lab check "o1" is no longer written from the real onboarding
        onFinish(flow)
    }

    @MainActor private func waitUntil(seconds: Int, _ condition: () -> Bool) async {
        var n = 0
        while !condition() && n < seconds * 5 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            n += 1
        }
    }
}

/// Developer → Show onboarding (the scooter stays paired).
struct ShowOnboardingRow: View {
    @State private var show = false

    var body: some View {
        Button {
            show = true
        } label: {
            Label("Show onboarding", systemImage: "hand.tap")
        }
        .fullScreenCover(isPresented: $show) {
            OnboardingView { _ in show = false }
        }
    }
}
