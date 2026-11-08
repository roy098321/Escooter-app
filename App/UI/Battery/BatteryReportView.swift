import Charts
import CorckieCore
import SwiftUI

/// V-U2 (batch 3): the battery decay report. Opens from the decay notice and from the Battery page's health tile (D9).
/// P-8: range in km leads, health % sits next to it. The graph has km on the left and health % on the right (one line, two units);
/// press and drag on it for the date, km and % at that point.
struct BatteryReportView: View {
    var preview: DecayReport?
    @State private var loaded: DecayReport?
    @State private var selected: DecayPoint?
    @State private var confirmReplace = false

    private var report: DecayReport? { preview ?? loaded }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.block) {
                if let r = report {
                    switch r.state {
                    case let .learning(weeks, kmSoFar): learning(weeks: weeks, kmSoFar: kmSoFar)
                    case .ready:
                        hero(r)
                        if r.points.count >= 2, let new = r.newKm { graph(r, newKm: new) }
                        rows(r)
                        if r.severity == .high { replaceCard(r) }
                    }
                    replaceButton
                } else {
                    learning(weeks: nil, kmSoFar: nil)
                }
            }
            .padding(DS.Space.gutter)
        }
        .background { MapBackdrop().ignoresSafeArea() }
        .navigationTitle("Battery report")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if preview == nil, let db = AppModel.shared.displayDatabase { loaded = BatteryDecayService.report(db) } }
        .confirmationDialog("Replaced the battery?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Yes, start a new baseline") {
                BatteryDecayService.replaced(AppModel.shared.database)
                if let db = AppModel.shared.displayDatabase { loaded = BatteryDecayService.report(db) }
            }
        } message: {
            Text("The report starts over for the new battery. Your rides stay.")
        }
        .screen("Battery report")
    }

    // MARK: parts

    private func learning(weeks: Int?, kmSoFar: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Still learning").font(.headline)
            Text(weeks.map { "About \($0) more week\($0 == 1 ? "" : "s") of rides." } ?? "Ride a few times first.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let km = kmSoFar {
                Text("Range on a full battery so far: \(Int(km.rounded())) km").font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
    }

    private func hero(_ r: DecayReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                bigNumber("Range on a full battery", r.nowKm.map { "\(Int($0.rounded())) km" } ?? "\u{2013}")
                Spacer(minLength: 12)
                bigNumber("Battery health", r.healthPct.map { "\(Int($0.rounded()))%" } ?? "\u{2013}")
            }
            HStack(spacing: 10) {
                if let s = r.severity { badge(s) }
                if let new = r.newKm { Text("New: \(Int(new.rounded())) km \u{00B7} 100%").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding(DS.Space.cardPad)
        .glassCard(radius: DS.Radius.hero, padding: 0)
    }

    private func bigNumber(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).scaledFont(34, weight: .bold, mono: true, relativeTo: .largeTitle).lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private func badge(_ s: DecaySeverity) -> some View {
        Label(s.title, systemImage: s == .low ? "info.circle" : "exclamationmark.triangle")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Self.colour(s))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Self.colour(s).opacity(0.15), in: Capsule())
    }

    static func colour(_ s: DecaySeverity) -> Color {
        switch s {
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        }
    }

    /// km on the left, health % on the right (the same line in two units); a dot at each level passed; press for the values
    private func graph(_ r: DecayReport, newKm: Double) -> some View {
        let lowest = min(r.points.map(\.healthPct).min() ?? 100, 70) - 5
        let levelLines = [90, 80, 70].filter { Double($0) >= lowest }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Range over time").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("km \u{00B7} health %").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(levelLines, id: \.self) { l in
                    RuleMark(y: .value("Level", newKm * Double(l) / 100))
                        .foregroundStyle(Self.colour(BatteryDecay.severity(level: l)).opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                ForEach(r.points, id: \.atMs) { p in
                    LineMark(x: .value("Date", Self.date(p.atMs)), y: .value("km", p.km))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                if let s = selected {
                    RuleMark(x: .value("Date", Self.date(s.atMs))).foregroundStyle(.secondary)
                    PointMark(x: .value("Date", Self.date(s.atMs)), y: .value("km", s.km)).symbolSize(80)
                        .annotation(position: .top, alignment: .center, spacing: 6) {
                            VStack(spacing: 1) {
                                Text(Self.date(s.atMs).formatted(date: .abbreviated, time: .omitted)).font(.caption2.weight(.semibold))
                                Text("\(Int(s.km.rounded())) km \u{00B7} \(Int(s.healthPct.rounded()))%").font(.caption.weight(.bold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .chartYScale(domain: newKm * lowest / 100 ... newKm * 1.03)
            .chartYAxis {
                AxisMarks(position: .leading, values: [100, 90, 80, 70].map { newKm * Double($0) / 100 }) { v in
                    AxisGridLine()
                    AxisValueLabel { if let km = v.as(Double.self) { Text("\(Int(km.rounded())) km") } }
                }
                AxisMarks(position: .trailing, values: [100, 90, 80, 70].map { newKm * Double($0) / 100 }) { v in
                    AxisValueLabel { if let km = v.as(Double.self) { Text("\(Int((km / newKm * 100).rounded()))%") } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard let plot = proxy.plotFrame else { return }
                                let x = g.location.x - geo[plot].origin.x
                                guard let d: Date = proxy.value(atX: x) else { return }
                                selected = r.points.min { abs(Self.date($0.atMs).timeIntervalSince(d)) < abs(Self.date($1.atMs).timeIntervalSince(d)) }
                            }
                            .onEnded { _ in selected = nil })
                }
            }
            .frame(height: 220)
            .accessibilityLabel("Range over time, from \(Int(newKm.rounded())) km new to \(Int((r.nowKm ?? newKm).rounded())) km now")
        }
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
    }

    private func rows(_ r: DecayReport) -> some View {
        VStack(spacing: 0) {
            if let l = r.losingKmPerYear, l > 0.05 {
                row("Losing", String(format: "~%.1f km of range a year", l))
            }
            if let next = r.nextLevelKm, let n = r.nextLevel {
                row("Next level", "~\(Int(next.rounded())) km (\(n)%)" + (r.nextLevelAtMs.map { " \u{00B7} \(Self.whenText($0))" } ?? ""))
            }
            row("Charge cycles", "\(Int(r.cycles.rounded()))")
            HStack {
                Text("Compared")
                Spacer()
                Text("rides in similar weather").foregroundStyle(.secondary)
                InfoButton("Compared", info: InfoContent(lead: "Cold weather shortens the range for a while and is not wear. Each ride is compared with your rides in similar weather when the battery was new, and a level counts only when it holds for 2 weeks."))
            }
            .font(.subheadline)
            .padding(.vertical, 10)
        }
        .padding(.horizontal, DS.Space.cardPad)
        .glassCard(padding: 0)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
            .padding(.vertical, 10)
            Divider()
        }
    }

    private func replaceCard(_ r: DecayReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Consider replacing the battery").font(.headline).foregroundStyle(.red)
            if let new = r.newKm, let now = r.nowKm {
                Text("A new battery brings back ~\(Int((new - now).rounded())) km per charge. Range drops faster from here.")
                    .font(.subheadline)
            }
            InfoButton("What to do next", info: InfoContent(lead: "Check the warranty first. Note the battery's spec from its label (voltage and Ah), and ask your dealer about a replacement."))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
    }

    private var replaceButton: some View {
        Button("I replaced the battery") { confirmReplace = true }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func whenText(_ ms: Int64) -> String {
        let months = Int((Double(ms) / 1000 - Date().timeIntervalSince1970) / (30 * 86_400))
        if months < 1 { return "within a month" }
        if months < 12 { return "in about \(months) month\(months == 1 ? "" : "s")" }
        let years = Int((Double(months) / 12).rounded())
        return "in about \(years) year\(years == 1 ? "" : "s")"
    }
}
