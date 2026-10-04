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
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(startAt: OnboardingFlow.Step = .connect, previewFound: Bool = false, onFinish: @escaping (OnboardingFlow) -> Void) {
        self.previewFound = previewFound
        self.onFinish = onFinish
        _flow = State(initialValue: OnboardingFlow(scooterFound: previewFound, startAt: startAt))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(flow.stepText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 24)
            Spacer()
            switch flow.step {
            case .connect: connectStep
            case .location: locationStep
            case .notifications: notificationsStep
            case .done: ProgressView()
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear {
            guard !previewFound else { return }
            AppModel.shared.scooter.start()
            PermissionsCheck.shared.refresh()
            refreshFound()
        }
        .onReceive(tick) { _ in refreshFound() }
    }

    // MARK: Steps

    private var connectStep: some View {
        VStack(spacing: 16) {
            Image(systemName: flow.scooterFound ? "checkmark.circle.fill" : "scooter")
                .font(.system(size: 64))
                .foregroundStyle(flow.scooterFound ? Color.green : Color.accentColor)
            Text("Connect your scooter").font(.title.bold())
            if flow.scooterFound {
                Text("Found your scooter (\(ScooterGatt.advertisedName)).").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    Text("Looking for your scooter. Switch it on and keep the phone close.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
            }
            bigButton("Connect", enabled: flow.canConnect) { _ = flow.press(.connect) }
            Button("Set up later") { skip() }
                .font(.footnote)
        }
    }

    private var locationStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "location.fill").font(.system(size: 64)).foregroundStyle(Color.accentColor)
            Text("Let rides start on their own").font(.title.bold()).multilineTextAlignment(.center)
            Text("Allow location (choose Always) and motion, so a ride is recorded with the phone locked in your pocket.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            bigButton(busy ? "Asking\u{2026}" : "Allow", enabled: !busy) { allowLocation() }
            Button("Not now") { finish(.notNow) }
                .font(.footnote)
                .disabled(busy)
        }
    }

    private var notificationsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.badge.fill").font(.system(size: 64)).foregroundStyle(Color.accentColor)
            Text("Weekly summary and reminders").font(.title.bold()).multilineTextAlignment(.center)
            Text("Allow notifications with sound for the \"Going for a ride?\" chime and the weekly summary.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            bigButton("Allow", enabled: !busy) { allowNotifications() }
            Button("Not now") { finish(.notNow) }
                .font(.footnote)
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
        flow.skipForNow()
        complete()
    }

    private func complete() {
        OnboardingState.done = true
        if !flow.skipped {
            CheckResults.shared.set("o1", flow.presses <= OnboardingFlow.stepCount ? .pass : .fail,
                                    "Real run: done in \(flow.presses) presses, ended on Home")
        }
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
                .v1Label()
        }
    }
}
