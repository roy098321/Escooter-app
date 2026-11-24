import ActivityKit
import Observation
import CorckieCore
import Foundation

/// N7-1 (batch 7): drives the scooter Live Activity (Shared/RideActivity, Widgets/ScooterLiveActivity): Ready on connect (gone after
/// ~2 min without a ride), Riding ("● Recording", grey when GPS is lost), Arrived (summary + End ride / Keep going), ended with the
/// ride. Never a mid-ride alert (P-4). Never learns WHEN the rider rides: the destination is the one chosen (or none).
final class ScooterActivityController {
    static let shared = ScooterActivityController()
    private var activity: Activity<ScooterActivityAttributes>?
    private var state: ScooterActivityAttributes.ContentState?
    private var readyTimer: DispatchWorkItem?
    private var recordingSince: Date?
    /// Keep going was pressed: no Arrived card again in this ride
    private var keptGoing = false
    static let readyS: TimeInterval = 120
    /// Hotfix .08: the riding card is re-sent at least this often, each time stale `staleAfterS` later (the widget then stops counting)
    static let refreshS: TimeInterval = 60
    static let staleAfterS: TimeInterval = 180
    private var lastPushAt: Date?

    /// The app's handlers for the shared intents (set once at launch)
    @MainActor func installIntents() {
        RideIntentBridge.start = { key in
            if let key {
                let chosen = key == "next" ? QuickDialNext.key() : key
                RouteFollowSelection.shared.choose(key: chosen)
            }
            RideVoice.shared.startTapped()
            RecorderService.shared.press(.startPressed)
        }
        RideIntentBridge.end = { RecorderService.shared.press(.endHeld) }
        RideIntentBridge.keepGoing = { [weak self] in
            self?.keptGoing = true
            self?.push(phase: .riding)
        }
        RideIntentBridge.changeDestination = { HomeRequests.shared.openWhereTo = true }
    }

    /// The scooter connected and no ride runs: the Ready card
    func connected(name: String, kmLeft: Int?, destination: String?) {
        guard state?.phase != .riding else { return }
        push(ScooterActivityAttributes.ContentState(phase: .ready, kmLeft: kmLeft, destination: destination), name: name)
        readyTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state?.phase == .ready else { return }
            self.end()
        }
        readyTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyS, execute: work)
    }

    /// Every live update (about once a second): Riding / Arrived; nothing when no ride runs
    func live(rideOn: Bool, gpsLost: Bool, arrived: Bool, destination: String?, distanceM: Double?, elapsedS: Double?, name: String) {
        guard rideOn else {
            if state?.phase == .riding || state?.phase == .arrived { end() }
            return
        }
        if recordingSince == nil { recordingSince = Date().addingTimeInterval(-(elapsedS ?? 0)) }
        readyTimer?.cancel()
        if arrived, !keptGoing {
            let km = (distanceM ?? 0) / 1000
            let min = Int(((elapsedS ?? 0) / 60).rounded())
            let summary = String(format: "%.1f km \u{00B7} %d min", km, min)
            let next = ScooterActivityAttributes.ContentState(phase: .arrived, destination: destination, summary: summary)
            if next != state { push(next, name: name) }
            return
        }
        let next = ScooterActivityAttributes.ContentState(phase: .riding, recordingSince: recordingSince, gpsLost: gpsLost)
        if next != state || Date().timeIntervalSince(lastPushAt ?? .distantPast) >= Self.refreshS { push(next, name: name) }
    }

    func end() {
        readyTimer?.cancel()
        state = nil
        recordingSince = nil
        keptGoing = false
        let all = Activity<ScooterActivityAttributes>.activities
        activity = nil
        for a in all { Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    private func push(phase: ScooterActivityAttributes.Phase) {
        guard var s = state else { return }
        s.phase = phase
        s.recordingSince = recordingSince
        push(s, name: nil)
    }

    private func push(_ s: ScooterActivityAttributes.ContentState, name: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        state = s
        lastPushAt = Date()
        let content = ActivityContent(state: s, staleDate: s.phase == .riding ? Date().addingTimeInterval(Self.staleAfterS) : nil)
        if activity == nil { activity = Activity<ScooterActivityAttributes>.activities.first }
        if let a = activity {
            Task { await a.update(content) }
        } else if let name {
            activity = try? Activity.request(attributes: ScooterActivityAttributes(name: name), content: content, pushType: nil)
            Log.info(source: "activity", activity == nil ? "scooter live activity refused" : "scooter live activity started")
        }
    }
}

/// N7-1: "Change" on the Ready card opens Home's Where to?
@Observable
final class HomeRequests {
    static let shared = HomeRequests()
    var openWhereTo = false
}

/// N7-9: the "Next" destination = the usual destination FROM THE PLACE YOU ARE AT (never by time of day); nil = free ride
enum QuickDialNext {
    static func key() -> String? {
        guard let db = AppModel.shared.displayDatabase else { return nil }
        let here = RecorderService.shared.livePosition.map { GeoPoint(lat: $0.lat, lon: $0.lon) }
        let items = QuickDialLoader.load(database: db, routeChips: RouteFollowLoader.chips(database: db, log: false), slots: 3, from: here).items
        return items.first { !$0.here }?.key
    }
}
