import Charts
import CorckieCore
import SwiftUI

/// F-31: the thin bar (optional 80 % tick), used on Home, the Scooter card and in the charge sheet.
struct ChargeBar: View {
    var progress: Double
    var tickAt: Double? = 0.8
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chip)
                Capsule().fill(Theme.accent).frame(width: max(height, g.size.width * min(1, max(0, progress))))
                if let t = tickAt {
                    Rectangle().fill(.primary.opacity(0.8)).frame(width: 2, height: height + 6).offset(x: g.size.width * t - 1)
                }
            }
            .frame(height: height).frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height + 6)
        .accessibilityHidden(true)
    }
}

/// The outlined pill next to Connect: "Plugged in" (offline) or "Unplugged" (while charging).
struct ChargePill: View {
    var charging: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(charging ? "Unplugged" : "Plugged in", systemImage: charging ? "bolt.slash.fill" : "bolt.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Theme.row.opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(charging ? "Unplugged" : "Plugged in")
    }
}

/// F-31 (3): the hero card's text column while charging: big ≈ %, Full ≈, time left, bar with the 80 % tick and the two times.
struct ChargingBlock: View {
    var session: ChargeSession
    var nowMs: Int64
    var utcOffsetMin: Int
    var onEdit: () -> Void = {}

    var body: some View {
        let pct = ChargeModel.pct(session, atMs: nowMs)
        let left = ChargeModel.minutesLeft(session, atMs: nowMs)
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Text(session.scooterName).font(.title3.weight(.semibold)).lineLimit(1)
                Image(systemName: "bolt.fill").font(.footnote).foregroundStyle(Theme.accent)
                Text("charging").font(.title3.weight(.semibold)).foregroundStyle(Theme.accentInk)
            }
            Text("\u{2248} \(Int(pct.rounded()))%")
                .scaledFont(52, weight: .semibold, mono: true, relativeTo: .largeTitle).minimumScaleFactor(0.6).lineLimit(1)
            Text(ChargeText.fullLine(session, utcOffsetMin: utcOffsetMin))
                .scaledFont(22, weight: .bold, mono: true, relativeTo: .title3).foregroundStyle(Theme.accentInk)
            Text(left == 0 ? "should be full" : "\(ChargeText.duration(minutes: left)) left").font(.subheadline).foregroundStyle(.secondary)
            ChargeBar(progress: pct / 100).padding(.top, 4)
            Text(ChargeText.ticksLine(session, utcOffsetMin: utcOffsetMin)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit what to be told")
    }
}

/// F-31 (2): the Home status pill while charging: "Charging · 72%  full ≈ 23:10" and a thin bar.
struct ChargeStatusLine: View {
    var session: ChargeSession
    var nowMs: Int64
    var utcOffsetMin: Int

    var body: some View {
        let pct = ChargeModel.pct(session, atMs: nowMs)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                Text("Charging \u{00B7} \u{2248} \(Int(pct.rounded()))%").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(ChargeText.fullLine(session, utcOffsetMin: utcOffsetMin).replacingOccurrences(of: "Full", with: "full"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accentInk).lineLimit(1).minimumScaleFactor(0.7)
            }
            ChargeBar(progress: pct / 100, tickAt: nil, height: 6)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: DS.hit)
        .glassCard(radius: 26, padding: 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charging, about \(Int(pct.rounded())) percent, \(ChargeText.fullLine(session, utcOffsetMin: utcOffsetMin))")
    }
}

// MARK: Battery log (F-27, N6-2)

/// N6-2 (batch 6): the Battery log. One battery line from ALL readings (rides as their smoothed level, so no load-sag spikes),
/// light fill, a dashed average line of what is shown ("avg 80%"), faint 0 / 50 / 100 grid and day lines, one headline
/// "51% now · 6 charges · 12 rides", Day / Week switch (tap a day in Week to open it). The legend is behind the ⓘ; a stretch
/// with no reading in between is a grey dashed line. No charging bands, no strips. Then the "Each charge" rows.
struct ChargeLogChartView: View {
    var readings: [ChargeReading]
    var rows: [ChargeRow]
    var info: InfoContent?
    var nowMs: Int64
    var rideStarts: [Int64] = []

    @State private var range: BatteryLog.Range = .week
    /// Day view: the local midnight of the day shown (nil = today)
    @State private var dayStartMs: Int64?

    private static let dayMs: Int64 = 86_400_000
    private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
    private var todayStartMs: Int64 { ms(Calendar.current.startOfDay(for: date(nowMs))) }
    private var isToday: Bool { range == .week || dayStartMs == nil || dayStartMs == todayStartMs }

    private var span: (fromMs: Int64, toMs: Int64) {
        switch range {
        case .week: return BatteryLog.weekRange(todayStartMs: todayStartMs, nowMs: nowMs)
        case .day: return BatteryLog.dayRange(dayStartMs: dayStartMs ?? todayStartMs, nowMs: nowMs)
        }
    }

    var body: some View {
        let sp = span
        let shown = BatteryLog.window(readings, fromMs: sp.fromMs, toMs: sp.toMs)
        let segs = ChargeLogChart.segments(shown)
        let avg = BatteryLog.average(shown)
        let charges = BatteryLog.chargeCount(rows, fromMs: sp.fromMs, toMs: sp.toMs)
        let rides = rideStarts.filter { $0 >= sp.fromMs && $0 <= sp.toMs }.count
        let big = isToday ? shown.last?.pct : avg
        let dayName = isToday ? nil : date(dayStartMs ?? todayStartMs).formatted(.dateTime.weekday(.abbreviated))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                if let info {
                    SectionHeader("Battery log") { InfoButton("Battery log", info: info) }
                } else {
                    SectionHeader("Battery log")
                }
                Spacer(minLength: 8)
                Picker("Range", selection: Binding(get: { range }, set: { r in
                    Haptics.tick()
                    range = r
                    dayStartMs = nil
                })) {
                    Text("Day").tag(BatteryLog.Range.day)
                    Text("Week").tag(BatteryLog.Range.week)
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(big.map { "\(Int($0.rounded()))%" } ?? "\u{2013}")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Text(BatteryLog.headline(charges: charges, rides: rides, range: range, dayName: dayName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                chart(shown: shown, segs: segs, avg: avg, sp: sp)
                    .frame(height: 200)
                Text(range == .week ? "Tap a day to open it." : "Back to Week to see all 7 days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
            .accessibilityElement(children: .combine)
            SectionHeader("Each charge")
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Label("No charge yet", systemImage: "bolt.slash").font(.subheadline).foregroundStyle(.secondary).padding(DS.Space.cardPad)
                }
                ForEach(rows) { r in ChargeRowView(row: r).padding(.vertical, 10) }
            }
            .padding(.horizontal, DS.Space.cardPad)
            .glassCard(padding: 0)
        }
    }

    private func chart(shown: [ChargeReading], segs: [ChargeLineSegment], avg: Double?, sp: (fromMs: Int64, toMs: Int64)) -> some View {
        let midnights = (0..<8).map { todayStartMs - Int64($0) * Self.dayMs }.filter { $0 > sp.fromMs && $0 < sp.toMs }
        // Week: one label per day (at noon, centred); Day: every 6 hours
        let ticks: [Date] = range == .week
            ? (0..<7).map { date(todayStartMs - Int64($0) * Self.dayMs + Self.dayMs / 2) }.filter { $0 > date(sp.fromMs) }
            : stride(from: sp.fromMs, through: sp.toMs, by: 6 * 3_600_000).map { date($0) }
        let week = range == .week
        return Chart {
            if range == .week {
                ForEach(midnights, id: \.self) { m in
                    RuleMark(x: .value("Day", date(m))).foregroundStyle(Color.secondary.opacity(0.15)).lineStyle(StrokeStyle(lineWidth: 0.5))
                }
            }
            ForEach(shown.indices, id: \.self) { i in
                AreaMark(x: .value("Time", date(shown[i].ms)), yStart: .value("Low", 0), yEnd: .value("%", shown[i].pct))
                    .foregroundStyle(Theme.accent.opacity(0.14))
                    .interpolationMethod(.linear)
            }
            ForEach(segs.indices, id: \.self) { i in
                let s = segs[i]
                ForEach([s.from, s.to], id: \.ms) { r in
                    LineMark(x: .value("Time", date(r.ms)), y: .value("%", r.pct), series: .value("Part", "s\(i)"))
                        .foregroundStyle(s.dashed ? Color.secondary : Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: s.dashed ? 1.5 : 2, dash: s.dashed ? [3, 4] : []))
                }
            }
            if let avg {
                RuleMark(y: .value("Average", avg))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(BatteryLog.averageText(avg))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                    }
            }
            if let last = shown.last, isToday {
                PointMark(x: .value("Time", date(last.ms)), y: .value("%", last.pct)).foregroundStyle(Theme.accent).symbolSize(60)
            }
        }
        .chartXScale(domain: date(sp.fromMs)...date(sp.toMs))
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) {
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text(week ? d.formatted(.dateTime.weekday(.abbreviated)) : d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { loc in
                        guard range == .week, let plot = proxy.plotFrame else { return }
                        let x = loc.x - g[plot].origin.x
                        guard let d: Date = proxy.value(atX: x) else { return }
                        Haptics.tick()
                        dayStartMs = ms(Calendar.current.startOfDay(for: d))
                        range = .day
                    }
            }
        }
        .accessibilityLabel(range == .week ? "Battery over the last 7 days" : "Battery over the day")
        .accessibilityValue(avg.map { "Average \(Int($0.rounded())) percent" } ?? "No readings")
    }
}

/// One "Each charge" row: day and start time, the 0-100 bar from the start % to the end % (solid = measured, lighter = ≈), +N % and how long.
struct ChargeRowView: View {
    var row: ChargeRow

    private func day(_ ms: Int64, _ fmt: String) -> String {
        let f = DateFormatter()
        f.dateFormat = fmt
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day(row.startMs, "EEE")).font(.body)
                Text(row.source == .away ? "away" : (row.source == .estimated ? "\u{2248} " : "") + day(row.startMs, "HH:mm"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width
                let x0 = min(w - 8, w * min(max(row.startPct, 0), 100) / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.chip)
                    Capsule().fill(Theme.accent.opacity(row.solid ? 1 : 0.45))
                        .frame(width: min(w - x0, max(8, w * row.gainedPct / 100))).offset(x: x0)
                }
                .frame(height: 14).frame(maxHeight: .infinity)
            }
            .frame(height: 20)
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(Int(row.gainedPct.rounded()))%").font(.body)
                Text(ChargeLogChart.detail(row).components(separatedBy: " \u{00B7} ").last ?? "").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day(row.startMs, "EEEE HH:mm")), \(ChargeLogChart.detail(row))")
    }
}
