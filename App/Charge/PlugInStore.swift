import CorckieCore
import Foundation
import SwiftUI

/// F-31b: the remembered alert choice (default 100 %), the last number on each side of Battery | Range, the last connect time, and
/// the one-tap start of the charge timer from the last reading. On the phone only (UserDefaults).
@MainActor
enum PlugInStore {
    private static let alertKey = "corckie.f31b.alert"
    private static let lastPctKey = "corckie.f31b.lastPct"
    private static let lastKmKey = "corckie.f31b.lastKm"
    private static let connectKey = "corckie.f31b.connectMs"

    static var alert: PlugAlert {
        get {
            guard let data = UserDefaults.standard.data(forKey: alertKey), let a = try? JSONDecoder().decode(PlugAlert.self, from: data) else { return .default }
            return a
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: alertKey) }
            switch newValue {
            case .battery(let p): UserDefaults.standard.set(p, forKey: lastPctKey)
            case .range(let km): UserDefaults.standard.set(km, forKey: lastKmKey)
            }
        }
    }

    static var lastPct: Int { (UserDefaults.standard.object(forKey: lastPctKey) as? Int) ?? 100 }
    static var lastKm: Int { (UserDefaults.standard.object(forKey: lastKmKey) as? Int) ?? PlugIn.defaultKm }

    /// Written by ScooterLink on every connect (the Plug in pill goes at the next connect)
    nonisolated static func noteConnect(atMs: Int64) { UserDefaults.standard.set(Double(atMs), forKey: connectKey) }
    static var lastConnectMs: Int64? {
        (UserDefaults.standard.object(forKey: connectKey) as? Double).map { Int64($0) }
    }

    /// The scooter's name for the texts ("G2 is full."): the name the rider gave it, else the Bluetooth name
    static func scooterName() -> String {
        guard let db = AppModel.shared.database else { return "Scooter" }
        return SettingsValue.text(db, ScooterTabView.nameKey) ?? ScooterRecord.latest(in: db)?.name ?? "Scooter"
    }

    /// A session as it would start now from the last reading (for the sheet's "18:02 estimated" before plugging in)
    static func draft(alert: PlugAlert) -> ChargeSession? {
        let t = ChargeTimer.shared
        if var running = t.session { running.target = PlugIn.target(alert); return running }
        guard let last = t.lastReading() else { return nil }
        let name = scooterName()
        let ctx = t.context(scooterName: name)
        return ChargeSession(startPct: Double(last.pct), startMs: t.now, target: PlugIn.target(alert), pctPerKm: ctx.pctPerKm,
                             reservePct: ctx.reserve, usualNeedPct: ctx.usualNeed, usualName: ctx.usualName, scooterName: name)
    }

    /// One tap: the timer starts from the last reading with the remembered alert, no form
    static func plugIn() {
        guard ChargeTimer.shared.canStart, let s = draft(alert: alert) else { return }
        ChargeTimer.shared.begin(s)
        Haptics.light()
        Log.info(source: "charge", "F-31b: Plug in from \(Int(s.startPct))%, alert \(alert.pillText)")
    }

    /// The sheet changed the alert: remembered, and a running timer is retargeted (notifications rescheduled)
    static func setAlert(_ a: PlugAlert) {
        alert = a
        if var s = ChargeTimer.shared.session {
            s.target = PlugIn.target(a)
            ChargeTimer.shared.update(s)
        }
    }
}

/// F-31b: Home after a ride: one big "⚡ Plug in" pill and the small alert pill ("100%" / "15 km"), no bell.
struct PlugInRow: View {
    let alert: PlugAlert
    var onPlug: () -> Void
    var onAlert: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlug) {
                Label("Plug in", systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Starts the charging timer from the last reading")
            Button(action: onAlert) {
                Text(alert.pillText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 52)
                    .background(Theme.row.opacity(0.92), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 2))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tell me at \(alert.pillText)")
            .accessibilityHint("Change when to be told")
        }
    }
}

/// F-31b: under the charge line while charging: the alert pill ("100% ≈ 18:02") and Unplugged
struct ChargeAlertRow: View {
    let text: String?
    var onAlert: () -> Void
    var onUnplug: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let text {
                Button(action: onAlert) {
                    Label(text, systemImage: "bell")
                        .labelStyle(.titleOnly)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Theme.row.opacity(0.92), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Alert \(text)")
            }
            Spacer(minLength: 0)
            ChargePill(charging: true, action: onUnplug)
        }
    }
}

/// F-31b: the only sheet: Battery | Range, a big number with − and +, and "18:02 estimated" (tap "estimated" for why)
struct PlugAlertSheet: View {
    @State var alert: PlugAlert
    /// The running timer, or how one would start now (nil: no reading yet)
    let session: ChargeSession?
    let utcOffsetMin: Int
    var onChange: (PlugAlert) -> Void

    @State private var showWhy = false
    @State private var typing = false
    @State private var typed = ""
    @State private var ticks = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GlassSegmented(options: [(false, "Battery"), (true, "Range")],
                           selection: Binding(get: { alert.isRange }, set: { range in
                               set(PlugIn.switched(alert, toRange: range, lastPct: PlugInStore.lastPct, lastKm: PlugInStore.lastKm))
                           }), slidingPill: true)
                .accessibilityLabel("Tell me by battery or by range")
            HStack {
                stepButton("minus", label: "Less", direction: -1)
                Spacer(minLength: 8)
                Button { typed = "\(alert.number)"; typing = true } label: {
                    Text(alert.isRange ? "\(alert.number) km" : "\(alert.number)%")
                        .scaledFont(52, weight: .semibold, mono: true, relativeTo: .largeTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alert.isRange ? "\(alert.number) kilometres" : "\(alert.number) percent")
                .accessibilityHint("Type a number")
                Spacer(minLength: 8)
                stepButton("plus", label: "More", direction: 1)
            }
            .padding(.horizontal, 8)
            timeLine
            if showWhy, let s = session {
                Text(PlugIn.why(s, alert, utcOffsetMin: utcOffsetMin))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .sensoryFeedback(.selection, trigger: ticks)
        .alert(alert.isRange ? "Range in km" : "Battery %", isPresented: $typing) {
            TextField(alert.isRange ? "km" : "%", text: $typed).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("OK") { if let a = PlugIn.typed(typed, for: alert) { set(a) } }
        }
    }

    @ViewBuilder private var timeLine: some View {
        if let s = session, let clock = PlugIn.alertClock(s, alert, utcOffsetMin: utcOffsetMin) {
            HStack(spacing: 6) {
                Text(clock).font(.title3.weight(.semibold).monospacedDigit())
                Button { withAnimation(.easeInOut(duration: 0.2)) { showWhy.toggle() } } label: {
                    Text("estimated").font(.title3).underline().foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("How it is worked out")
                Spacer(minLength: 0)
            }
        } else {
            Text(session == nil ? "Connect once to read the battery first." : PlugIn.needsRidesText)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func stepButton(_ symbol: String, label: String, direction: Int) -> some View {
        Button { set(PlugIn.stepped(alert, by: direction)) } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
                .background(Theme.chip, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func set(_ a: PlugAlert) {
        guard a != alert else { return }
        alert = a
        ticks += 1
        onChange(a)
    }
}
