import CorckieCore
import SwiftUI

/// B81 (hotfix 103.081126.02): Settings → Ride not recorded. One question, one button; the app says the cause when it can tell.
struct MissedRideView: View {
    @State private var when: MissedRideWhen = .justNow
    @State private var roughStart = Date().addingTimeInterval(-3 * 3600)
    @State private var saved = false
    @State private var cause: String?
    @State private var saving = false

    var body: some View {
        List {
            Section {
                Picker("When did you ride?", selection: $when) {
                    ForEach(MissedRideWhen.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: when) { _, w in
                    let base = w == .yesterday ? Date().addingTimeInterval(-86_400) : Date().addingTimeInterval(-3 * 3600)
                    roughStart = base
                    saved = false
                }
                if when != .justNow {
                    DatePicker("Started about", selection: $roughStart, displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("When did you ride?")
            }
            .glassRows()

            Section {
                if saved {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(cause == nil ? "Saved" : "Found it", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                        Text(cause ?? "Saved. It goes with your next export.").font(.subheadline)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        save()
                    } label: {
                        Label(saving ? "Saving\u{2026}" : "Save report", systemImage: "square.and.arrow.down")
                    }
                    .disabled(saving)
                }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Ride not recorded?")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Ride not recorded")
    }

    private func save() {
        saving = true
        let start = when == .justNow ? nil : Self.roughStartMs(when, roughStart)
        let w = when
        DispatchQueue.main.async {
            cause = MissedRideReports.save(when: w, roughStartMs: start, auto: false)
            saving = false
            saved = true
            Haptics.soft()
        }
    }

    /// The picked clock time on today (or yesterday)
    static func roughStartMs(_ when: MissedRideWhen, _ time: Date) -> Int64 {
        let cal = Calendar.current
        let day = when == .yesterday ? cal.date(byAdding: .day, value: -1, to: Date())! : Date()
        let c = cal.dateComponents([.hour, .minute], from: time)
        let d = cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: day) ?? time
        return Int64(d.timeIntervalSince1970 * 1000)
    }
}

/// B81: Settings → Export log. Everything the app logs in one zip (at most 5 MB, oldest detail left out first).
struct ExportLogView: View {
    @State private var result: LogExporter.Result?
    @State private var error: String?
    @State private var making = false
    @State private var level: PrivacyLevel = .full      // N5-1

    var body: some View {
        List {
            Section {
                Picker("Include", selection: $level) {
                    ForEach(PrivacyLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: level) { _, _ in result = nil }
                Text(level.detail).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if let r = result {
                    ShareLink(item: r.url) {
                        Label("Share log (\(ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file)))", systemImage: "square.and.arrow.up")
                    }
                    if let left = r.leftOut { Text(left).font(.footnote).foregroundStyle(.secondary) }
                    Button("Make a fresh log") { make() }.disabled(making)
                } else {
                    Button {
                        make()
                    } label: {
                        Label(making ? "Preparing\u{2026}" : "Prepare log", systemImage: "doc.zipper")
                    }
                    .disabled(making)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("Everything the app logs, at most 5 MB. It stays on this phone unless you share it.")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Export log")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Export log")
    }

    private func make() {
        making = true
        DispatchQueue.main.async {
            do {
                result = try LogExporter.make(level: level)
                error = nil
            } catch {
                self.error = "Log failed: \(error.localizedDescription)"
                Log.error(source: "export", "Export log: \(error.localizedDescription)")
            }
            making = false
        }
    }
}
