import Charts
import CorckieCore
import GRDB
import SwiftUI

/// N10-14 (batch 10, owner 20 Nov: the FULL service book; mock reports/maintenance/mock/history2.png): opened from the clock button
/// on the Maintenance screen. Battery card (km on a full charge + health %, the V-U2 decay line, dashed 90 % first-notice line),
/// counts (logged · found · dealt with · open), Export as PDF (English / עברית), a timeline by year with Measured / Entered marks;
/// fault rows show their outcome. Never places, routes or times of day.
struct MaintenanceHistoryView: View {
    /// N11-2: a Sold / Lost scooter's service book (read-only, still exports); nil = the active scooter
    var scooterId: String? = nil
    @State private var header = ""
    @State private var entries: [HistoryEntry] = []
    @State private var decay: DecayReport?
    @State private var askLanguage = false
    @State private var shareURL: ShareItem?

    struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(header).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
                if let d = decay, d.nowKm != nil || d.healthPct != nil { batteryCard(d) }
                countsCard
                Button { askLanguage = true } label: {
                    Label("Export as PDF", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                ForEach(MaintHistory.byYear(entries, year: HistoryDates.year), id: \.year) { group in
                    Text(String(group.year)).font(.headline).foregroundStyle(Theme.accentInk).padding(.top, 6).padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { i, e in
                            HistoryRow(entry: e)
                            if i < group.entries.count - 1 { Divider().padding(.leading, 72) }
                        }
                    }
                    .background(Theme.row, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, 24)
        }
        .navigationTitle("History")
        .confirmationDialog("Choose the language for the maintenance history.", isPresented: $askLanguage, titleVisibility: .visible) {
            Button("English") { export(.english) }
            Button("עברית") { export(.hebrew) }
        }
        .sheet(item: $shareURL) { item in ShareSheet(url: item.url) }
        .onAppear(perform: load)
    }

    private func batteryCard(_ d: DecayReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Battery").font(.headline)
                Spacer()
                Text("since tracking started").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                if let km = d.nowKm {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(km.rounded())) km").font(.largeTitle.weight(.heavy))
                        Text("on a full charge" + (d.newKm.map { " \u{00B7} new \(Int($0.rounded())) km" } ?? ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let h = d.healthPct {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(h.rounded()))%").font(.largeTitle.weight(.heavy)).foregroundStyle(Theme.accentInk)
                        Text("battery health").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if d.points.count >= 2 {
                Chart {
                    ForEach(d.points, id: \.atMs) { p in
                        AreaMark(x: .value("Date", Date(timeIntervalSince1970: Double(p.atMs) / 1000)), y: .value("Health", p.healthPct))
                            .foregroundStyle(Theme.accent.opacity(0.12))
                        LineMark(x: .value("Date", Date(timeIntervalSince1970: Double(p.atMs) / 1000)), y: .value("Health", p.healthPct))
                            .foregroundStyle(Theme.accent)
                    }
                    RuleMark(y: .value("First notice", 90))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.accentInk)
                        .annotation(position: .top, alignment: .leading) { Text("90 % \u{00B7} first notice").font(.caption2) }
                }
                .chartYScale(domain: max(80, (d.points.map(\.healthPct).min() ?? 90) - 3)...max(101, (d.points.map(\.healthPct).max() ?? 100) + 1))
                .chartYAxisLabel("health %")
                .frame(height: 150)
                .accessibilityLabel("Battery health over time")
            }
            Text("Range on a full charge, rides in similar weather. \(Int(d.cycles.rounded())) charge cycles.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(DS.Space.cardPad)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private var countsCard: some View {
        let c = MaintHistory.counts(entries)
        return HStack {
            ForEach([(c.logged, "logged"), (c.found, "found"), (c.dealtWith, "dealt with"), (c.open, "open")], id: \.1) { n, label in
                VStack(spacing: 2) {
                    Text("\(n)").font(.title.weight(.heavy))
                    Text(label).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 14)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private func load() {
        guard let db = AppModel.shared.database else { return }
        let active = MaintenanceService.scooterId(db)
        let id = scooterId ?? active
        entries = MaintHistory.entries(logged: MaintenanceService.logged(db), faults: FaultStore.records(db), scooterId: id,
                                       trackedSince: HistoryDates.trackedSince(db))
        let since = HistoryDates.trackedSince(db).map { " \u{00B7} tracked since " + HistoryDates.monthYear($0.day) } ?? ""
        if id == active {
            decay = BatteryDecayService.report(db)
            header = MaintenanceService.header(db) + since
        } else {
            let g = GarageService.registry(db).scooter(id)
            decay = nil
            header = [g?.displayName ?? "Scooter", g?.status.label].compactMap { $0 }.joined(separator: " \u{00B7} ") + since
        }
    }

    private func export(_ lang: ReportLanguage) {
        guard let db = AppModel.shared.database, let url = HistoryPDF.make(db, language: lang, scooterId: scooterId) else { return }
        shareURL = ShareItem(url: url)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if entry.isFault {
                    Text("!").font(.title3.weight(.heavy)).foregroundStyle(Theme.accentInk)
                } else if let p = entry.part {
                    Image(systemName: PartIcon.symbol(p)).foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 44, height: 44)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.body.weight(.semibold))
                Text(HistoryDates.dayMonth(entry.day) + (entry.odoKm.map { " \u{00B7} \(Int($0.rounded()).formatted()) km" } ?? ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let o = entry.outcome { chip(o.rawValue, filled: true, tint: o == .open ? Theme.accentInk : .green) }
                    chip(entry.source.rawValue, filled: entry.source == .measured, tint: entry.source == .measured ? Theme.accentInk : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, filled: Bool, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(filled ? tint.opacity(0.15) : .clear, in: Capsule())
            .overlay(Capsule().stroke(filled ? .clear : tint.opacity(0.6), lineWidth: 1))
    }
}

/// Day numbers (days since 1970, UTC) → the rider's calendar, for display only
enum HistoryDates {
    static func date(_ day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200) }   // midday: no time-zone flip
    static func year(_ day: Int) -> Int { Calendar.current.component(.year, from: date(day)) }
    static func dayMonth(_ day: Int) -> String { date(day).formatted(.dateTime.day().month(.abbreviated)) }
    static func monthYear(_ day: Int) -> String { date(day).formatted(.dateTime.month(.abbreviated).year()) }

    /// The first recorded (not simulated) ride: its day and the odometer then
    static func trackedSince(_ db: AppDatabase) -> (day: Int, odoKm: Double?)? {
        let row = try? db.writer.read { d in
            try Row.fetchOne(d, sql: "SELECT startAt, odoStartKm FROM ride WHERE isSimulated = 0 ORDER BY startAt ASC LIMIT 1")
        }
        guard let r = row, let at: Int64 = r["startAt"] else { return nil }
        return (FaultGate.day(epochMs: at), r["odoStartKm"])
    }
}
