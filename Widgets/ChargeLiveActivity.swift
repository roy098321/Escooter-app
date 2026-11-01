import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CorckieWidgets: WidgetBundle {
    var body: some Widget { ChargeLiveActivity() }
}

private let orange = Color(red: 0.973, green: 0.576, blue: 0.333)
private let clock24 = Locale(identifier: "en_GB")

/// R4 + B68 (hotfix 02 / batch 102): a Live Activity view is only redrawn when the app sends an update, so everything that must move
/// while the app sleeps is a SYSTEM timer: the battery-shaped fill (`ProgressView(timerInterval:)` masked into a battery outline, marks
/// at 25 / 50 / 75 %) and the countdown to the target (`Text(timerInterval:countsDown:)`). No % number (it froze, B68).
/// The clock time ("full ≈ 11:18") is a secondary line in the expanded Dynamic Island only.
private extension ChargeActivityAttributes.ContentState {
    /// What the countdown runs to: the target % if one is set below 100, else full
    var endAt: Date { targetAt ?? fullAt }
    /// "to 100%" / "to 80%"
    var toText: String { "to \(targetPct ?? 100)%" }

    /// now ... end (never an empty or reversed range)
    func countdown(_ now: Date = Date()) -> ClosedRange<Date> { now...max(now, endAt) }
}

/// F-31 (1): the lock-screen card and the Dynamic Island.
struct ChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            LockCard(name: context.attributes.name, state: context.state)
                .activityBackgroundTint(Color(white: 0.12))
                .activitySystemActionForegroundColor(orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.attributes.name) charging", systemImage: "bolt.fill").foregroundStyle(orange).font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.countdown(), countsDown: true)
                        .font(.title3.weight(.bold)).monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 90)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        BatteryFill(state: context.state, height: 18)
                        HStack {
                            (Text("Full \u{2248} ") + Text(context.state.fullAt, style: .time)).environment(\.locale, clock24)
                            Spacer()
                            Text(context.state.toText).foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }
            } compactLeading: {
                Image(systemName: "bolt.fill").foregroundStyle(orange)
            } compactTrailing: {
                Text(timerInterval: context.state.countdown(), countsDown: true)
                    .monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "bolt.fill").foregroundStyle(orange)
            }
        }
    }
}

private struct LockCard: View {
    let name: String
    let state: ChargeActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(name) charging", systemImage: "bolt.fill").foregroundStyle(orange).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\u{2248} estimate").font(.caption).foregroundStyle(.secondary)
            }
            BatteryFill(state: state, height: 30)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timerInterval: state.countdown(), countsDown: true)
                    .font(.system(size: 28, weight: .bold)).monospacedDigit()
                Text(state.toText).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
    }
}

/// B68: a battery outline whose fill moves by itself (system timer from the 0 % moment of the line to the 100 % moment, so the fill
/// is the real ≈ % at any time), with marks at 25 / 50 / 75 %.
private struct BatteryFill: View {
    let state: ChargeActivityAttributes.ContentState
    let height: CGFloat

    var body: some View {
        let radius = height * 0.28
        HStack(spacing: 2) {
            ZStack {
                ProgressView(timerInterval: state.zeroAt...max(state.zeroAt, state.fullAt), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(orange)
                .labelsHidden()
                .scaleEffect(x: 1, y: height / 3, anchor: .center)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                GeometryReader { geo in
                    ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                        Rectangle()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 1.5, height: height * 0.5)
                            .position(x: geo.size.width * f, y: geo.size.height / 2)
                    }
                }
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
            }
            .frame(height: height)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.white.opacity(0.85))
                .frame(width: 4, height: height * 0.42)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charging, the battery fills up")
    }
}
