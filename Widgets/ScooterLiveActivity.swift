import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let orange = Color(red: 0.973, green: 0.576, blue: 0.333)

/// N7-1 (batch 7): the scooter's card on the Lock Screen and in the Dynamic Island: Ready → Riding → Arrived. Quiet by design:
/// no alerts during a ride (P-4). Buttons run the shared App Intents in the app.
struct ScooterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScooterActivityAttributes.self) { context in
            ScooterLockCard(name: context.attributes.name, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color(white: 0.12))
                .activitySystemActionForegroundColor(orange)
        } dynamicIsland: { context in
            let s = context.state
            let ticking = s.phase == .riding && !context.isStale   // hotfix .08: a card the app stopped updating never counts on
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.isStale && s.phase == .riding ? staleTitle : title(s, context.attributes.name), systemImage: symbol(s))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(phaseColour(s)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if ticking, let since = s.recordingSince {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .font(.title3.weight(.bold)).monospacedDigit().frame(maxWidth: 90).foregroundStyle(phaseColour(s))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ScooterCardBody(state: s, stale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: symbol(s)).foregroundStyle(phaseColour(s))
            } compactTrailing: {
                if ticking, let since = s.recordingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .monospacedDigit().frame(maxWidth: 56).foregroundStyle(phaseColour(s))
                } else if s.phase == .ready, let km = s.kmLeft {
                    Text("\(km) km").monospacedDigit()
                } else {
                    Image(systemName: "flag.fill")
                }
            } minimal: {
                Image(systemName: symbol(s)).foregroundStyle(phaseColour(s))
            }
        }
    }
}

/// Hotfix .08 (B-ride-never-ended, 24 Nov): the app refreshes the riding card every minute with a 3-min stale date. A card that went
/// stale (the app was stopped or missed the end) says so instead of counting up forever.
private let staleTitle = "Not updating"
private let staleLine = "Open the app to check the ride"

private func symbol(_ s: ScooterActivityAttributes.ContentState) -> String {
    switch s.phase {
    case .ready: return "scooter"
    case .riding: return s.gpsLost ? "location.slash" : "record.circle"
    case .arrived: return "flag.fill"
    }
}

private func phaseColour(_ s: ScooterActivityAttributes.ContentState) -> Color {
    s.phase == .riding && s.gpsLost ? .gray : (s.phase == .riding ? .red : orange)
}

private func title(_ s: ScooterActivityAttributes.ContentState, _ name: String) -> String {
    switch s.phase {
    case .ready: return "\(name) ready"
    case .riding: return s.gpsLost ? "GPS lost" : "Recording"
    case .arrived: return s.destination.map { "Arrived at \($0)" } ?? "Arrived"
    }
}

private struct ScooterCardBody: View {
    let state: ScooterActivityAttributes.ContentState
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.phase {
            case .ready:
                Text(readyLine).font(.subheadline).lineLimit(2)
                HStack(spacing: 8) {
                    Button(intent: StartRideIntent(destination: nil)) {
                        Label("Start ride", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .tint(orange)
                    Button(intent: ChangeDestinationIntent()) {
                        Text("Change").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            case .riding:
                Text(stale ? staleLine : (state.gpsLost ? "Still recording · GPS lost" : "Recording your ride")).font(.footnote).foregroundStyle(.secondary)
            case .arrived:
                if let summary = state.summary { Text(summary).font(.subheadline.weight(.semibold)).monospacedDigit() }
                HStack(spacing: 8) {
                    Button(intent: EndRideIntent()) { Text("End ride").frame(maxWidth: .infinity) }
                        .tint(orange)
                    Button(intent: KeepGoingIntent()) { Text("Keep going").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var readyLine: String {
        var parts: [String] = []
        if let km = state.kmLeft { parts.append("\u{2248} \(km) km left") }
        if let d = state.destination {
            parts.append(state.arrivalPct.map { "\(d) \u{00B7} arrive with ~\($0)%" } ?? d)
        }
        return parts.isEmpty ? "Ready to ride" : parts.joined(separator: " \u{00B7} ")
    }
}

private struct ScooterLockCard: View {
    let name: String
    let state: ScooterActivityAttributes.ContentState
    var stale = false

    var body: some View {
        let frozen = stale && state.phase == .riding
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(frozen ? staleTitle : title(state, name), systemImage: symbol(state))
                    .foregroundStyle(frozen ? Color.gray : phaseColour(state)).font(.subheadline.weight(.semibold))
                Spacer()
                if !frozen, state.phase == .riding, let since = state.recordingSince {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(phaseColour(state))
                }
            }
            ScooterCardBody(state: state, stale: stale)
        }
        .padding(16)
    }
}
