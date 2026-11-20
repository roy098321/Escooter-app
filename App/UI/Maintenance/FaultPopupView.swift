import Charts
import CorckieCore
import SwiftUI

/// N10-12 (batch 10): the fault warning OVER the ride summary (mock reports/maintenance/mock/popup.png, approved 20 Nov 2026), also
/// used over Home at switch-on. One fault at a time: a massive warning triangle, the title, one line; red adds "It's not safe to
/// keep riding." on its own bold line and what to do. Buttons: Tell me more (solid) · Export a report (outlined) · Got it (text).
/// F16 is a grey info card with one OK. Never says it's OK to ride.
struct FaultPopupView: View {
    let record: FaultRecord
    var onTellMore: () -> Void
    var onExport: (() -> Void)?
    var onClose: () -> Void

    static let red = Color(hex: "#C81E1E")
    static let amber = Color(hex: "#C2410C")

    private var text: FaultText { FaultCopy.text(record.kind) }
    private var level: FaultLevel { record.kind.level }
    private var tint: Color { level == .red ? Self.red : level == .amber ? Self.amber : .secondary }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                if level == .info {
                    Image(systemName: "info.circle")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 120, weight: .light))
                        .foregroundStyle(tint)
                        .frame(width: 150, height: 150)
                        .accessibilityHidden(true)
                }
                Text(text.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                Text(text.line)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary.opacity(0.85))
                if level == .red {
                    Text(FaultCopy.notSafe)
                        .font(.body.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 10)
                    if let todo = text.todo {
                        Text(todo)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                    }
                }
                if level == .info {
                    Button("OK", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .tint(.gray)
                        .controlSize(.large)
                        .padding(.top, 20)
                } else {
                    Button(action: onTellMore) {
                        Text(FaultCopy.tellMeMore).font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .controlSize(.large)
                    .padding(.top, 20)
                    if let onExport {
                        Button(action: onExport) {
                            Text(FaultCopy.exportReport).font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(tint)
                        .controlSize(.large)
                        .padding(.top, 8)
                    }
                    Button(FaultCopy.gotIt, action: onClose)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)
            .frame(maxWidth: 380)
            .background(Theme.row, in: RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
            .padding(.horizontal, DS.Space.gutter)
            .accessibilityElement(children: .contain)
        }
        .transition(.opacity)
    }
}

/// Tell me more: what was found, what to do, and "Checked, it's fine" / "I fixed it" (the full fault page with "your last 10
/// rides vs your normal" lives on the Maintenance screen, N10-13)
struct FaultDetailSheet: View {
    let record: FaultRecord
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: FaultRecord?

    var body: some View {
        let t = FaultCopy.text(record.kind)
        NavigationStack {
            List {
                Section("What was found") {
                    Text(t.found)
                    FaultNormalChart(record: record)      // your last rides vs your normal
                }
                Section("What to do") { Text(t.what) }
                if record.kind.level != .info {
                    Section {
                        Button { exporting = record } label: { Label(FaultCopy.exportReport, systemImage: "square.and.arrow.up") }
                    } footer: {
                        Text("A report for a mechanic: what the app measured, as a PDF and a data file. No map, places or times.")
                    }
                }
                if let km = record.odoKm {
                    Section { LabeledContent("Found at", value: "\(Int(km.rounded())) km") }
                }
                Section {
                    Button(FaultCopy.fixedIt) {
                        FaultStore.fixed(record.id, AppModel.shared.database)
                        close()
                    }
                    Button(FaultCopy.checkedFine) {
                        FaultStore.checkedFine(record.id, AppModel.shared.database)
                        close()
                    }
                } footer: {
                    Text("\"Checked, it's fine\" makes the app less sensitive to this. Twice, and it stays quiet.")
                }
            }
            .navigationTitle(t.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
            .mechanicExport($exporting)
        }
    }

    private func close() {
        dismiss()
        onDone()
    }
}

/// N10-15: "Export a report" → a small pop-up English / עברית → the PDF + CSV made on the phone → the share sheet
struct MechanicExport: ViewModifier {
    @Binding var record: FaultRecord?
    @State private var files: Files?

    struct Files: Identifiable {
        let urls: [URL]
        var id: String { urls.map(\.path).joined() }
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Choose the language for the report.", isPresented: Binding(get: { record != nil }, set: { if !$0 { record = nil } }),
                                titleVisibility: .visible, presenting: record) { r in
                Button("English") { make(r, .english) }
                Button("עברית") { make(r, .hebrew) }
            }
            .sheet(item: $files) { f in FilesShareSheet(urls: f.urls) }
    }

    private func make(_ r: FaultRecord, _ lang: ReportLanguage) {
        guard let db = AppModel.shared.database else { return }
        let urls = MechanicReport.make(db, record: r, language: lang)
        record = nil
        if !urls.isEmpty { files = Files(urls: urls) }
    }
}

extension View {
    func mechanicExport(_ record: Binding<FaultRecord?>) -> some View { modifier(MechanicExport(record: record)) }
}

struct FilesShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// N10-12: shows FaultCenter's pop-up wherever it is placed (over the ride summary, over Home); Tell me more and Export a report
struct FaultPopupHost: View {
    @State private var detail: FaultRecord?
    @State private var exporting: FaultRecord?

    var body: some View {
        if let r = FaultCenter.shared.popup {
            FaultPopupView(record: r,
                           onTellMore: { detail = r },
                           onExport: { exporting = r },
                           onClose: { FaultCenter.shared.dismissPopup() })
                .sheet(item: $detail) { rec in
                    FaultDetailSheet(record: rec, onDone: { FaultCenter.shared.dismissPopup() })
                }
                .mechanicExport($exporting)
        }
    }
}

/// N10-13 fault page picture: your normal band (the learned rides, lowest to highest) and the last rides past it
struct FaultNormalChart: View {
    let record: FaultRecord

    var body: some View {
        let db = AppModel.shared.database
        let book = FaultStore.load(db, FaultStore.bookKey, as: FaultBook.self) ?? FaultBook()
        let prefix = FaultBook.key(record.scooterId, record.kind)
        let base = book.baselines.filter { $0.key == prefix || $0.key.hasPrefix(prefix + "|") }.values.max { $0.samples.count < $1.samples.count }
        let occ = (FaultStore.load(db, FaultStore.occurrencesKey, as: [FaultOccurrence].self) ?? [])
            .filter { $0.kind == record.kind && $0.scooterId == record.scooterId }.suffix(10)
        let unit = MechanicText.unit(record.kind)
        if let b = base, let lo = b.samples.min(), let hi = b.samples.max(), !unit.isEmpty, !occ.isEmpty {
            let points = Array(occ.enumerated())
            Chart {
                RectangleMark(xStart: .value("from", 0), xEnd: .value("to", max(1, points.count - 1)),
                              yStart: .value("low", lo), yEnd: .value("high", hi))
                    .foregroundStyle(Color.secondary.opacity(0.18))
                ForEach(points, id: \.offset) { p in
                    PointMark(x: .value("Ride", p.offset), y: .value(unit, p.element.value))
                        .foregroundStyle(Theme.accent)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxisLabel(unit)
            .frame(height: 140)
            .accessibilityLabel("Your last rides compared with your normal")
            Text("Grey band: your normal. Dots: the last rides where it showed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
