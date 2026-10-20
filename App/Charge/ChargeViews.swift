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

// MARK: Charge log (F-27)

/// The 7-day battery line (real readings only, long gaps dashed), charge windows shaded, and "Each charge" rows.
struct ChargeLogChartView: View {
    var readings: [ChargeReading]
    var rows: [ChargeRow]
    var info: InfoContent?
    var nowMs: Int64

    private var from: Date { Date(timeIntervalSince1970: Double(nowMs - Int64(ChargeLogChart.windowDays) * 86_400_000) / 1000) }
    private var to: Date { Date(timeIntervalSince1970: Double(nowMs) / 1000) }
    private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    var body: some View {
        let segs = ChargeLogChart.segments(ChargeLogChart.lastWeek(readings, nowMs: nowMs))
        let recent = rows.filter { $0.endMs >= Int64(from.timeIntervalSince1970 * 1000) }
        VStack(alignment: .leading, spacing: 0) {
            if let info {
                SectionHeader("Charge log \u{00B7} last 7 days") { InfoButton("Charge log", info: info) }
            } else {
                SectionHeader("Charge log \u{00B7} last 7 days")
            }
            VStack(alignment: .leading, spacing: 10) {
                Chart {
                    ForEach(recent) { r in
                        RectangleMark(xStart: .value("From", date(r.startMs)), xEnd: .value("To", date(r.endMs)), yStart: .value("Low", 0), yEnd: .value("High", 100))
                            .foregroundStyle(Theme.accent.opacity(r.solid ? 0.22 : 0.12))
                    }
                    ForEach(segs.indices, id: \.self) { i in
                        let s = segs[i]
                        LineMark(x: .value("Time", date(s.from.ms)), y: .value("%", s.from.pct), series: .value("Part", "s\(i)"))
                            .foregroundStyle(s.dashed ? Theme.accent : Color.primary)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, dash: s.dashed ? [4, 4] : []))
                        LineMark(x: .value("Time", date(s.to.ms)), y: .value("%", s.to.pct), series: .value("Part", "s\(i)"))
                            .foregroundStyle(s.dashed ? Theme.accent : Color.primary)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, dash: s.dashed ? [4, 4] : []))
                    }
                    if let last = ChargeLogChart.lastWeek(readings, nowMs: nowMs).last {
                        PointMark(x: .value("Time", date(last.ms)), y: .value("%", last.pct)).foregroundStyle(Theme.accent).symbolSize(70)
                    }
                }
                .chartXScale(domain: from...to)
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 180)
                HStack(spacing: 14) {
                    Label("charging", systemImage: "square.fill").foregroundStyle(Theme.accent).font(.caption)
                    Label("dashed: no reading in between", systemImage: "line.diagonal").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(DS.Space.cardPad)
            .glassCard(padding: 0)
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
