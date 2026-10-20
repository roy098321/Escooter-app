import CorckieCore
import SwiftUI

/// F-31 (sheet2.png): "Plugged in". Shows the start % (last reading), "Also tell me when it has" Battery % / Range in km / Ready by,
/// the full line with its 5 % notification margin, and Start charging timer. The ⋯ corrects the start %.
struct ChargeSheet: View {
    enum Mode: Hashable { case battery, range, readyBy }
    enum PctChoice: Hashable { case off, p80, p90, other }

    /// Everything the sheet shows without touching the phone (ui-shots and checks pass it in)
    struct Input {
        var scooterName: String
        var lastPct: Int?
        var lastMs: Int64?
        var nowMs: Int64
        var utcOffsetMin: Int
        var pctPerKm: Double?
        var reserve: Double
        var usualNeed: Double?
        var usualName: String?
        /// a running timer being edited (start stays), else nil
        var editing: ChargeSession?
    }

    let input: Input
    var preset: (mode: Mode, pct: PctChoice, km: String)?
    var onStart: (ChargeSession) -> Void

    @State private var mode: Mode = .battery
    @State private var pctChoice: PctChoice = .p80
    @State private var customPct = 70
    @State private var kmText = "10"
    @State private var readyAt = Date()
    @State private var correcting = false
    @State private var startPct = 50
    @Environment(\.dismiss) private var dismiss

    init(input: Input, preset: (mode: Mode, pct: PctChoice, km: String)? = nil, onStart: @escaping (ChargeSession) -> Void) {
        self.input = input
        self.preset = preset
        self.onStart = onStart
        _mode = State(initialValue: preset?.mode ?? Self.mode(of: input.editing?.target))
        _pctChoice = State(initialValue: preset?.pct ?? Self.choice(of: input.editing?.target))
        _kmText = State(initialValue: preset?.km ?? Self.km(of: input.editing?.target))
        _startPct = State(initialValue: Int((input.editing?.startPct ?? Double(input.lastPct ?? 50)).rounded()))
        _correcting = State(initialValue: input.lastPct == nil && input.editing == nil)
        var ready = Date(timeIntervalSince1970: Double(ChargeModel.nextOccurrence(minuteOfDay: 7 * 60 + 30, afterMs: input.nowMs, utcOffsetMin: input.utcOffsetMin)) / 1000)
        if let e = input.editing, case .readyBy(let at) = e.target { ready = Date(timeIntervalSince1970: Double(at) / 1000) }
        _readyAt = State(initialValue: ready)
    }

    private static func mode(of t: ChargeTarget?) -> Mode {
        switch t { case .km: return .range; case .readyBy: return .readyBy; default: return .battery }
    }
    private static func choice(of t: ChargeTarget?) -> PctChoice {
        guard let t else { return .p80 }
        if case .pct(let p) = t { return p == 80 ? .p80 : p == 90 ? .p90 : .other }
        return .off
    }
    private static func km(of t: ChargeTarget?) -> String {
        if case .km(let k) = t { return k == k.rounded() ? "\(Int(k))" : String(k) }
        return "10"
    }

    // MARK: The session being built

    private var target: ChargeTarget {
        switch mode {
        case .battery:
            switch pctChoice { case .off: return .none; case .p80: return .pct(80); case .p90: return .pct(90); case .other: return .pct(customPct) }
        case .range:
            return Double(kmText.replacingOccurrences(of: ",", with: ".")).map { .km($0) } ?? .none
        case .readyBy:
            let c = Calendar.current.dateComponents([.hour, .minute], from: readyAt)
            return .readyBy(atMs: ChargeModel.nextOccurrence(minuteOfDay: (c.hour ?? 0) * 60 + (c.minute ?? 0), afterMs: input.editing?.startMs ?? input.nowMs, utcOffsetMin: input.utcOffsetMin))
        }
    }

    private var draft: ChargeSession {
        if var e = input.editing { e.target = target; e.startPct = Double(startPct); return e }
        return ChargeSession(startPct: Double(startPct), startMs: input.nowMs, target: target, pctPerKm: input.pctPerKm, reservePct: input.reserve,
                             usualNeedPct: input.usualNeed, usualName: input.usualName, scooterName: input.scooterName)
    }

    private var off: Int { input.utcOffsetMin }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(input.editing == nil ? "Plugged in" : "Charging", systemImage: "bolt.fill")
                    .font(.title3.weight(.semibold)).fontDesign(.rounded)
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.palette)
                Spacer()
                Menu {
                    Button { correcting = true } label: { Label("Correct start %", systemImage: "pencil") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(width: DS.hit, height: DS.hit)
                }
                .accessibilityLabel("More")
            }
            startRow
            Text("Also tell me when it has").font(.subheadline).foregroundStyle(.secondary)
            GlassSegmented(options: [(Mode.battery, "Battery %"), (Mode.range, "Range in km"), (Mode.readyBy, "Ready by")], selection: $mode, slidingPill: true)
            modeBody
            Divider()
            Text(ChargeText.sheetFullLine(draft, utcOffsetMin: off)).font(.footnote).foregroundStyle(.secondary)
            Button { onStart(draft); dismiss() } label: {
                Text(input.editing == nil ? "Start charging timer" : "Update").font(.headline).foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// "Starting at 18% · last reading 18:52"; the ⋯ turns it into − / +
    @ViewBuilder private var startRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Starting at").font(.body)
                Spacer()
                if correcting {
                    Button { startPct = max(0, startPct - 1) } label: { Image(systemName: "minus").frame(width: DS.hit, height: DS.hit) }.accessibilityLabel("Less")
                    Text("\(startPct)%").scaledFont(28, weight: .bold, mono: true, relativeTo: .title).frame(minWidth: 64)
                    Button { startPct = min(100, startPct + 1) } label: { Image(systemName: "plus").frame(width: DS.hit, height: DS.hit) }.accessibilityLabel("More")
                } else {
                    Text("\(startPct)%").scaledFont(28, weight: .bold, mono: true, relativeTo: .title)
                    if let ms = input.lastMs, input.editing == nil {
                        Text("last reading \(ChargeText.clock(ms, utcOffsetMin: off))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if correcting {
                Text("Only if the dash shows something else. The real reading replaces it on the next connect.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var modeBody: some View {
        switch mode {
        case .battery:
            HStack(spacing: 8) {
                chip("Off", .off)
                chip("80 %", .p80)
                chip("90 %", .p90)
                chip(pctChoice == .other ? "\(customPct) %" : "Other\u{2026}", .other)
            }
            if pctChoice == .other {
                Stepper("Tell me at \(customPct) %", value: $customPct, in: 1...100, step: 5).font(.subheadline)
            }
            if case .pct(let p) = target {
                Text("\(p) % \u{2248} \(ChargeText.clock(ChargeModel.timeMs(toPct: Double(p), draft), utcOffsetMin: off))").font(.footnote).foregroundStyle(.secondary)
            }
        case .range:
            HStack {
                Text("I need")
                Spacer()
                TextField("10", text: $kmText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .scaledFont(28, weight: .bold, mono: true, relativeTo: .title).frame(maxWidth: 90)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.accent).frame(height: 2) }
                Text("km").scaledFont(28, weight: .bold, mono: true, relativeTo: .title)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if case .km(let km) = target {
                Text(ChargeText.kmLine(draft, km: km, utcOffsetMin: off).map { $0.replacingOccurrences(of: " \u{00B7} ", with: " (with safety margin and reserve) \u{00B7} ") }
                     ?? "Needs a few rides first: your % per km is not known yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .readyBy:
            DatePicker("Ready by", selection: $readyAt, displayedComponents: .hourAndMinute)
                .font(.body)
            if case .readyBy(let at) = target {
                Text(ChargeText.readyByLine(draft, atMs: at, utcOffsetMin: off)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ title: String, _ value: PctChoice) -> some View {
        let on = pctChoice == value
        return Button { pctChoice = value } label: {
            Text(title).font(.body).frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.chip, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
