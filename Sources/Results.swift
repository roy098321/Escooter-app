import SwiftUI

// Every P2 check with a clear status, plus one export for Claude.
enum TestStatus: String, Codable {
    case pending, pass, fail, info

    var icon: String {
        switch self {
        case .pending: return "⏳"
        case .pass: return "✅"
        case .fail: return "❌"
        case .info: return "ℹ️"
        }
    }
}

struct TestItem: Identifiable {
    let id: String
    let group: String
    let title: String
    let how: String
    let manual: Bool
}

enum Tests {
    static let groups = ["Phone only", "Scooter standing still (D03, D04)", "On a ride (D05, D07, D11)"]

    static let all: [TestItem] = [
        TestItem(id: "d08", group: groups[0], title: "D08 Backup folder: write", how: "Backup folder → Pick folder → Write test file", manual: false),
        TestItem(id: "d08r", group: groups[0], title: "D08 Backup folder: write after a restart", how: "Restart the phone, then Backup folder → Write test file", manual: false),
        TestItem(id: "d09own", group: groups[0], title: "D09 Our crash catcher", how: "Crash reports → Crash the app now → reopen", manual: false),
        TestItem(id: "d09mk", group: groups[0], title: "D09 iOS crash report arrives", how: "Arrives by itself after a crash", manual: false),
        TestItem(id: "d07baro", group: groups[0], title: "D07 Barometer: one floor", how: "Barometer → walk up one floor and back", manual: true),
        TestItem(id: "d05loc", group: groups[0], title: "D05 Location while locked", how: "Background location → Start → lock and walk 5 min", manual: false),
        TestItem(id: "d10", group: groups[0], title: "D10 Ride Replay plays in the app", how: "Ride Replay viewer → choose the file → play at 50×", manual: true),
        TestItem(id: "d02bg", group: groups[0], title: "D02 SideStore refreshes by itself", how: "Before 8 Oct: did the apps renew without you tapping Refresh?", manual: true),

        TestItem(id: "d03conn", group: groups[1], title: "D03 Connects to the scooter", how: "Scooter on, open D03 Bluetooth", manual: false),
        TestItem(id: "d03data", group: groups[1], title: "D03 Live data makes sense", how: "Speed, battery and voltage in normal ranges", manual: false),
        TestItem(id: "t0", group: groups[1], title: "T0 Baseline", how: "D04 → T0", manual: false),
        TestItem(id: "t1", group: groups[1], title: "T1 Headlight", how: "D04 → T1", manual: false),
        TestItem(id: "t2", group: groups[1], title: "T2 Modes", how: "D04 → T2", manual: false),
        TestItem(id: "t3", group: groups[1], title: "T3 Brake", how: "D04 → T3", manual: false),
        TestItem(id: "t4", group: groups[1], title: "T4 Throttle", how: "D04 → T4 (wheel lifted)", manual: false),
        TestItem(id: "t7", group: groups[1], title: "T7 Lock", how: "D04 → T7 (if the display has a lock)", manual: false),
        TestItem(id: "t9", group: groups[1], title: "T9 Device info", how: "Read automatically when connected", manual: false),
        TestItem(id: "t10", group: groups[1], title: "T10 Charging", how: "D04 → T10 with the charger", manual: false),
        TestItem(id: "t11", group: groups[1], title: "T11 Cold start", how: "D04 → T11 next morning", manual: false),
        TestItem(id: "t13", group: groups[1], title: "T13 Lowest speed (2 km/h?)", how: "D04 → T13 (wheel lifted, then walking)", manual: false),
        TestItem(id: "t14", group: groups[1], title: "T14 Autostart traps", how: "D04 → T14", manual: false),
        TestItem(id: "t8", group: groups[1], title: "T8 Power off", how: "D04 → T8 (do it last)", manual: false),
        TestItem(id: "pack", group: groups[1], title: "Battery pack size on the label", how: "D04 → Battery label", manual: false),

        TestItem(id: "d05wake", group: groups[2], title: "D05 App wakes when the scooter turns on", how: "Ride test → steps 1–2", manual: false),
        TestItem(id: "d05ble", group: groups[2], title: "D05 Scooter data while locked", how: "Ride with the phone locked", manual: false),
        TestItem(id: "d05locwake", group: groups[2], title: "D05 Location starts after a wake-up", how: "Ride with the phone locked", manual: false),
        TestItem(id: "d05ride", group: groups[2], title: "D05 A 30-min ride recorded completely", how: "Ride test → after the ride", manual: true),
        TestItem(id: "d07bridge", group: groups[2], title: "D07 Arch bridge shows as a climb", how: "Ride test → elevation chart after riding over it", manual: true),
        TestItem(id: "d11read", group: groups[2], title: "D11 Live view readable on the mount", how: "Readability → Normal, while riding", manual: true),
        TestItem(id: "d11sun", group: groups[2], title: "D11 Sunlight style readable in sun", how: "Readability → Sunlight, in direct sun", manual: true)
    ]
}

final class ResultStore: ObservableObject {
    static let shared = ResultStore()

    struct Entry: Codable {
        var status: TestStatus
        var note: String
        var date: Date
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: "results"),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
        // Checks already passed with build 4 on 1 Oct.
        if !defaults.bool(forKey: "seededBuild4") {
            defaults.set(true, forKey: "seededBuild4")
            for id in ["d08", "d09own", "d09mk", "d07baro", "d05loc"] where entries[id] == nil {
                set(id, .pass, "Passed on 1 Oct (build 4)")
            }
            if entries["d10"] == nil { set("d10", .info, "Plays (1 Oct); the viewer's design comes later") }
        }
    }

    func status(_ id: String) -> TestStatus { entries[id]?.status ?? .pending }
    func note(_ id: String) -> String { entries[id]?.note ?? "" }

    func set(_ id: String, _ status: TestStatus, _ note: String = "") {
        if let current = entries[id], current.status == status, current.note == note { return }
        entries[id] = Entry(status: status, note: note, date: .now)
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: "results")
        }
    }

    func badge(_ ids: [String]) -> String {
        let all = ids.map(status)
        if all.contains(.fail) { return "❌" }
        if all.contains(.pending) { return all.allSatisfy({ $0 == .pending }) ? "⏳" : "◐" }
        return "✅"
    }

    func report() -> String {
        var out = "P2 Lab results · \(Date.now.formatted())\n"
        for group in Tests.groups {
            out += "\n\(group)\n"
            for item in Tests.all where item.group == group {
                let entry = entries[item.id]
                out += "\(status(item.id).icon) \(item.title)"
                if let entry, !entry.note.isEmpty { out += " — \(entry.note)" }
                if let entry { out += " (\(entry.date.formatted(date: .abbreviated, time: .shortened)))" }
                out += "\n"
            }
        }
        return out
    }
}

/// Pass / Fail buttons for checks only a person can judge.
struct ManualResult: View {
    let id: String
    @ObservedObject private var store = ResultStore.shared

    var body: some View {
        HStack {
            Text(store.status(id).icon)
            Spacer()
            Button("Pass") { store.set(id, .pass) }
                .buttonStyle(.bordered).tint(.green)
            Button("Fail") { store.set(id, .fail) }
                .buttonStyle(.bordered).tint(.red)
        }
    }
}

struct ResultsView: View {
    @ObservedObject private var store = ResultStore.shared
    @State private var exportFiles: [URL] = []

    var body: some View {
        List {
            Section {
                let statuses = Tests.all.map { store.status($0.id) }
                HStack {
                    count("✅", statuses.filter { $0 == .pass }.count)
                    count("❌", statuses.filter { $0 == .fail }.count)
                    count("ℹ️", statuses.filter { $0 == .info }.count)
                    count("⏳", statuses.filter { $0 == .pending }.count)
                }
            }
            ForEach(Tests.groups, id: \.self) { group in
                Section(group) {
                    ForEach(Tests.all.filter { $0.group == group }) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(store.status(item.id).icon)
                                Text(item.title).font(.body.weight(.medium))
                            }
                            Text(store.note(item.id).isEmpty ? item.how : store.note(item.id))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if item.manual {
                                ManualResult(id: item.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section {
                if exportFiles.isEmpty {
                    Button("Prepare export for Claude") { exportFiles = Exporter.files() }
                } else {
                    ShareLink(items: exportFiles) {
                        Label("Share results + scooter log", systemImage: "square.and.arrow.up")
                    }
                    Button("Refresh export") { exportFiles = Exporter.files() }
                }
            } footer: {
                Text("Shares a results summary, the Bluetooth events and the raw scooter log. Send them to Claude.")
            }
        }
        .navigationTitle("Results")
    }

    private func count(_ icon: String, _ n: Int) -> some View {
        VStack {
            Text(icon)
            Text("\(n)").font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

enum Exporter {
    static func files() -> [URL] {
        let folder = FileManager.default.temporaryDirectory
        let summary = folder.appendingPathComponent("p2-lab-results.txt")
        let log = folder.appendingPathComponent("p2-lab-scooter-log.csv")
        let text = ResultStore.shared.report()
            + "\nBluetooth events\n" + Scooter.shared.events.joined(separator: "\n")
            + "\n\nDevice info\n" + Scooter.shared.deviceInfoText.joined(separator: "\n")
            + "\n\nElevation\n" + AltitudeRecorder.shared.summary
        try? text.write(to: summary, atomically: true, encoding: .utf8)
        try? Scooter.shared.csv().write(to: log, atomically: true, encoding: .utf8)
        return [summary, log]
    }
}
