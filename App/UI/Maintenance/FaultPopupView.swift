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

    var body: some View {
        let t = FaultCopy.text(record.kind)
        NavigationStack {
            List {
                Section("What was found") { Text(t.found) }
                Section("What to do") { Text(t.what) }
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
        }
    }

    private func close() {
        dismiss()
        onDone()
    }
}
