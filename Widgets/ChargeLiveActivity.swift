import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CorckieWidgets: WidgetBundle {
    var body: some Widget { ChargeLiveActivity() }
}

private let orange = Color(red: 0.973, green: 0.576, blue: 0.333)
private let clock24 = Locale(identifier: "en_GB")

/// ≈ % at a moment, from the line through (zeroAt, 0 %) and (fullAt, 100 %)
private func pct(_ s: ChargeActivityAttributes.ContentState, at now: Date = Date()) -> Int {
    let span = s.fullAt.timeIntervalSince(s.zeroAt)
    guard span > 0 else { return 100 }
    return Int(min(100, max(0, now.timeIntervalSince(s.zeroAt) / span * 100)).rounded())
}

/// F-31 (1): the lock-screen card and the Dynamic Island.
struct ChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            LockCard(name: context.attributes.name, pluggedAt: context.attributes.pluggedAt, state: context.state)
                .activityBackgroundTint(Color(white: 0.12))
                .activitySystemActionForegroundColor(orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.attributes.name) charging", systemImage: "bolt.fill").foregroundStyle(orange).font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\u{2248} \(pct(context.state)) %").font(.title3.weight(.bold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("Full \u{2248} ") + Text(context.state.fullAt, style: .time)
                        Spacer()
                        Text(context.state.fullAt, style: .relative) + Text(" left")
                    }
                    .font(.footnote).environment(\.locale, clock24)
                }
            } compactLeading: {
                Image(systemName: "bolt.fill").foregroundStyle(orange)
            } compactTrailing: {
                Text(context.state.fullAt, style: .time).environment(\.locale, clock24).monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "bolt.fill").foregroundStyle(orange)
            }
        }
    }
}

private struct LockCard: View {
    let name: String
    let pluggedAt: Date
    let state: ChargeActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(name) charging", systemImage: "bolt.fill").foregroundStyle(orange).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\u{2248} estimate").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\u{2248} \(pct(state)) %").font(.system(size: 34, weight: .bold)).monospacedDigit()
                Spacer()
                (Text("Full \u{2248} ") + Text(state.fullAt, style: .time)).font(.title3.weight(.bold)).environment(\.locale, clock24)
            }
            // the bar runs from the 0 % moment of the line, so its position is the real ≈ % at any time
            ProgressView(timerInterval: state.zeroAt...state.fullAt, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(orange)
            HStack(spacing: 0) {
                Text(state.fullAt, style: .relative) + Text(" left \u{00B7} plugged in ") + Text(pluggedAt, style: .time)
            }
            .font(.caption).foregroundStyle(.secondary).environment(\.locale, clock24)
        }
        .padding(16)
    }
}
