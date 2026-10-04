import Foundation
import Observation
import UIKit

/// On-device checks (TESTING §6): the build's whole check list ships in its first build.
/// ✅ passed · ❌ failed · ⏳ not done · ℹ️ recorded for analysis.
enum CheckStatus: String, Codable {
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

/// Which developer screen runs a check.
enum CheckTool: String {
    case none, scooter, sensors, simulator, backup, crash, outside, readability, results, permissions
}

struct CheckItem: Identifiable {
    let id: String
    let group: String
    let title: String
    let how: String
    let expected: String
    let needsScooter: Bool
    /// Only a person can judge it: Pass / Fail buttons
    let manual: Bool
    let tool: CheckTool
}

/// The P4 foundation build's check list: TESTING §6 P4 row + the P6 carry-overs that fit.
/// IDs are stable: the export and docs/P4_RUN_ORDER.md use them.
enum CheckList {
    static let install = "Install and update"
    static let scooter = "Scooter standing still"
    static let background = "Phone locked"
    static let phone = "Phone only"
    static let outside = "Outside data"
    static let ride = "On a ride (P6 carry-overs)"
    static let send = "Send"

    static let groups = [install, scooter, background, phone, outside, ride, send]

    static let all: [CheckItem] = [
        CheckItem(id: "h1", group: install, title: "Permissions", how: "Developer → Permissions: allow everything; Location must be \"Always\"",
                  expected: "Location Always, Notifications, Motion, Bluetooth all allowed", needsScooter: false, manual: false, tool: .permissions),
        CheckItem(id: "h2", group: install, title: "Notification sounds on", how: "Developer → Permissions → step 6 (Sounds on)",
                  expected: "Sounds: on (needed for the Kick-off chime)", needsScooter: false, manual: false, tool: .permissions),
        CheckItem(id: "a1", group: install, title: "Installs and opens", how: "Install with SideStore, open the app",
                  expected: "Marks itself on first open", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "a2", group: install, title: "Name and icon on the Home Screen", how: "Look at the Home Screen",
                  expected: "Scooter icon; name \"CorckieApp\" in full", needsScooter: false, manual: true, tool: .none),
        CheckItem(id: "a7", group: install, title: "v1 label visible on every screen", how: "Look at the bottom-right corner on every tab, pushed screen, sheet and Developer screen",
                  expected: "Small \"v1 · 0.5 (build)\" label, never covering anything", needsScooter: false, manual: true, tool: .none),
        CheckItem(id: "a3", group: install, title: "Permanent app ID", how: "Nothing to do",
                  expected: "com.corckieapp.app (+ SideStore team suffix)", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "a4", group: install, title: "Update keeps data", how: "Install the same .ipa again over the app in SideStore (or let SideStore refresh it), then open",
                  expected: "Same install ID, launch count keeps growing", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "a5", group: install, title: "SideStore refreshes by itself (D02)", how: "Before the 7 days run out: did SideStore renew the apps without you tapping Refresh?",
                  expected: "Expiry date moved on by itself", needsScooter: false, manual: true, tool: .none),
        CheckItem(id: "a6", group: install, title: "Database ready (data versioning)", how: "Nothing to do",
                  expected: "Schema v1 applied, not read-only", needsScooter: false, manual: false, tool: .none),

        CheckItem(id: "b1", group: scooter, title: "Bluetooth connects", how: "Scooter on → Developer → Scooter",
                  expected: "Connected to G2", needsScooter: true, manual: false, tool: .scooter),
        CheckItem(id: "b2", group: scooter, title: "Live decode makes sense", how: "Stay on the Scooter screen ~10 s",
                  expected: "Speed 0, battery %, 40–55 V, no ignored readings", needsScooter: true, manual: false, tool: .scooter),
        CheckItem(id: "b3", group: scooter, title: "Firmware fingerprint", how: "Read on connect",
                  expected: "BK-BLE-1.0 · fw 6.1.2 · sw 6.3.0", needsScooter: true, manual: false, tool: .scooter),
        CheckItem(id: "b4", group: scooter, title: "Read-only link", how: "Read on connect",
                  expected: "Only the data stream subscribed; command / firmware services listed as untouched", needsScooter: true, manual: false, tool: .scooter),
        CheckItem(id: "b5", group: scooter, title: "Lock bit (T7)", how: "Scooter screen → Lock: Record, lock and unlock 3×, Stop (or \"No lock on this scooter\")",
                  expected: "A lock bit toggles", needsScooter: true, manual: false, tool: .scooter),
        CheckItem(id: "b8", group: scooter, title: "Stable for 4 min", how: "Scooter on, app open on Scooter → Start 4-min test; keep the screen on",
                  expected: "0 disconnects in 4 min (reasons logged if any)", needsScooter: true, manual: false, tool: .scooter),
        CheckItem(id: "b9", group: scooter, title: "Out of range and back", how: "Scooter → Arm range test, lock the phone, walk away until it drops, come back",
                  expected: "Reconnects by itself without opening the app (seconds recorded)", needsScooter: true, manual: false, tool: .scooter),
        CheckItem(id: "c1", group: background, title: "Wakes when the scooter turns on", how: "Scooter off · Home Screen (don't swipe the app away) · lock the phone · scooter on · wait 30 s",
                  expected: "Connected while in the background", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "c2", group: background, title: "Scooter data while locked", how: "Keep the phone locked ~1 min after the wake-up",
                  expected: "100+ packets while locked", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "c3", group: background, title: "Location while locked", how: "Starts with the wake-up (or Sensors → Start), lock, walk ~2 min",
                  expected: "20+ fixes while locked", needsScooter: false, manual: false, tool: .sensors),
        CheckItem(id: "c4", group: background, title: "Barometer while locked", how: "Same recording as location",
                  expected: "20+ readings while locked", needsScooter: false, manual: false, tool: .sensors),

        CheckItem(id: "c5", group: background, title: "Wakes after a phone restart", how: "Scooter off · restart the phone · unlock once but don't open the app · scooter on · wait 30 s",
                  expected: "The scooter woke the app before you opened it", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "c6", group: background, title: "Notification on a scooter wake", how: "Allow notifications · app in the background, phone locked · scooter on",
                  expected: "Silent \"Scooter on · 91% · test: going for a ride?\" arrives (tap it too)", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "c6b", group: background, title: "Kick-off chime heard (ringer on)", how: "Ringer on · do the c6 steps · listen",
                  expected: "The Kick-off chime plays with the notification", needsScooter: true, manual: true, tool: .sensors),
        CheckItem(id: "c7", group: background, title: "Low Power Mode wake", how: "Turn Low Power Mode on · repeat the c1 wake · lock, walk ~1 min",
                  expected: "Woke, 20+ packets and 5+ fixes while locked", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "c8", group: background, title: "Full ride with the phone locked", how: "Sensors → Start recording, ride 20+ min with the phone locked, then Stop",
                  expected: "Recorded: packet gaps > 2 s, fixes, barometer, phone battery per 30 min", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "d1", group: phone, title: "Simulator ride at 50×", how: "Developer → Simulated scooter → Ride 1 → 50× → Start",
                  expected: "\"SIMULATED\" banner; ride 1 finishes with ~437 Wh, 16.3 km", needsScooter: false, manual: false, tool: .simulator),
        CheckItem(id: "d2", group: phone, title: "Backup folder: write", how: "Developer → Backup folder → Pick folder (e.g. iCloud Drive › CorckieApp) → Write test file",
                  expected: "Written and read back", needsScooter: false, manual: false, tool: .backup),
        CheckItem(id: "d3", group: phone, title: "Backup folder after a restart (D08)", how: "Restart the phone → Backup folder → Write test file",
                  expected: "Wrote again after a restart", needsScooter: false, manual: false, tool: .backup),
        CheckItem(id: "d4", group: phone, title: "Crash catcher", how: "Developer → Crash catcher → Crash the app now → open the app again",
                  expected: "Caught the test crash", needsScooter: false, manual: false, tool: .crash),
        CheckItem(id: "d5", group: phone, title: "iOS crash report (MetricKit)", how: "Arrives by itself, up to a day after the crash",
                  expected: "iOS delivered a crash report", needsScooter: false, manual: false, tool: .crash),
        CheckItem(id: "d6", group: phone, title: "Error log", how: "Developer → Crash catcher → Write a test entry",
                  expected: "Entry stored in the database and read back", needsScooter: false, manual: false, tool: .crash),

        CheckItem(id: "u1", group: phone, title: "Checks show progress and step ticks (M1-00b)", how: "Start the 4-min test (b8) or Run all automatic, and watch this screen",
                  expected: "A bar with time left on the 4-min test and on Run all automatic; b9 / c5 / c6 / c7 show a checklist that ticks itself", needsScooter: false, manual: true, tool: .none),
        CheckItem(id: "u2", group: phone, title: "Version 0.5 and thresholds (M1-01)", how: "Nothing to do · Run all automatic also marks it",
                  expected: "Version 0.5; speed warning on above 45 km/h, off below 43 (T99); safety margin +10% (T101)", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u3", group: phone, title: "Fake scooter replays phone GPS + barometer (M1-02)", how: "Nothing to do · Run all automatic marks it",
                  expected: "The ride-2 phone track lines up with the scooter samples (≤ 5 m); GPS and barometer replay on the same clock", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u4", group: phone, title: "Ride storage (M1-08)", how: "Nothing to do · Run all automatic marks it",
                  expected: "A test ride with samples, raw chunk, gap and stop is written, read back and deleted in a temporary database; your real rides are unchanged", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u5", group: phone, title: "Ride numbers from stored samples (M1-06)", how: "Nothing to do · Run all automatic marks it",
                  expected: "Ride 1 gives 437 Wh and 16.3 km, ride 2 gives 322 Wh and 13.7 km (±3% energy), top speed, peak temperature and time computed from one sample every 5 s", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "d7", group: phone, title: "Simulated disconnect (phone takes over)", how: "Simulated scooter → Fault \"D7 · Disconnect at 40%\" → 50× → Start",
                  expected: "GPS speed shown (labelled) during the gap; totals stay scooter-only", needsScooter: false, manual: false, tool: .simulator),
        CheckItem(id: "d8", group: phone, title: "Simulator keeps real data apart", how: "Any simulator run",
                  expected: "Real database ride count unchanged", needsScooter: false, manual: false, tool: .simulator),
        CheckItem(id: "d9", group: phone, title: "Restore from backup", how: "Backup folder → Test backup + restore",
                  expected: "A test backup restored into a scratch database with the same rows", needsScooter: false, manual: false, tool: .backup),
        CheckItem(id: "e1", group: outside, title: "Fuel price setting ready (manual)", how: "Nothing to do · Settings → Fuel price to change it",
                  expected: "Manual 8.27 ₪/L, Oct 2026 (owner, P4 D4)", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "e2", group: outside, title: "Holidays (Hebcal)", how: "Same",
                  expected: "This year's Israeli holidays", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e3", group: outside, title: "Weather forecast (Open-Meteo)", how: "Same",
                  expected: "Hourly wind, gusts, rain, temperature", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e3b", group: outside, title: "Forecast at your real location", how: "Location allowed → Outside data → Run all",
                  expected: "Forecast for your area (not the fallback point)", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e4", group: outside, title: "Backup forecast (MET Norway)", how: "Same",
                  expected: "Hourly wind, rain, temperature", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e5", group: outside, title: "Weather history (Open-Meteo)", how: "Same",
                  expected: "Yesterday's hourly wind and rain", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e6", group: outside, title: "Map elevation (Open-Meteo DEM)", how: "Same",
                  expected: "Elevation in metres", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e6b", group: outside, title: "Elevation at your real location", how: "Same",
                  expected: "Elevation for your area (not the fallback point)", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e7", group: outside, title: "Replay map tiles (CARTO, OSM)", how: "Same",
                  expected: "A map tile image from each", needsScooter: false, manual: false, tool: .outside),

        CheckItem(id: "e8", group: outside, title: "No internet", how: "Airplane mode on → Outside data → Run all",
                  expected: "Every source shows its fallback, no crash", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "f1", group: ride, title: "Arch bridge shows as a climb (D07)", how: "Ride over the bridge with Sensors recording, then look at the elevation chart",
                  expected: "A clear bump", needsScooter: true, manual: true, tool: .sensors),
        CheckItem(id: "f2", group: ride, title: "Readable on the mount (D11)", how: "Developer → Readability → Normal, phone on the mount",
                  expected: "Speed and battery readable at a glance", needsScooter: true, manual: true, tool: .readability),
        CheckItem(id: "f3", group: ride, title: "Readable in direct sun (D11)", how: "Readability → Sunlight, in direct sun",
                  expected: "Readable", needsScooter: true, manual: true, tool: .readability),

        CheckItem(id: "g1", group: send, title: "Export to Claude", how: "Developer → Results → Prepare export → Share",
                  expected: "One .zip: results, error log, Bluetooth events, raw packets", needsScooter: false, manual: false, tool: .results)
    ]

    static func item(_ id: String) -> CheckItem? { all.first { $0.id == id } }
}

/// Check results, kept in UserDefaults (developer data, survives a broken database).
@Observable
final class CheckResults {
    static let shared = CheckResults()

    struct Entry: Codable {
        var status: CheckStatus
        var note: String
        var date: Date
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let key = "corckie.checkResults.p4"
    /// Results are only saved once the stored ones are loaded, so a wake before the first unlock
    /// after a restart (settings unreadable) can never overwrite them.
    @ObservationIgnored private var loaded = false
    /// The owner's own notes per check (M1-00): kept across updates, in the export
    private(set) var notes: [String: String] = [:]
    @ObservationIgnored private let notesKey = "corckie.checkNotes"

    private init() {
        loadIfPossible()
    }

    func loadIfPossible() {
        guard !loaded, UIApplication.shared.isProtectedDataAvailable else { return }
        var saved: [String: Entry] = [:]
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            saved = decoded
        }
        entries = saved.merging(entries) { _, new in new }
        let savedNotes = defaults.dictionary(forKey: notesKey) as? [String: String] ?? [:]
        notes = savedNotes.merging(notes) { _, new in new }
        loaded = true
        // Owner verdicts (4 Oct 2026), seeded once like the P2 Lab build-4 seeding
        if !defaults.bool(forKey: "corckie.seeded.p4b") {
            defaults.set(true, forKey: "corckie.seeded.p4b")
            if status("f1") != .pass {
                entries["f1"] = Entry(status: .pass, note: "Passed (owner: similar climbs read fine, 2026-10-04)", date: Date())
            }
        }
        persist()
    }

    private func persist() {
        guard loaded, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
        defaults.set(notes, forKey: notesKey)
    }

    func ownerNote(_ id: String) -> String { notes[id] ?? "" }

    func setOwnerNote(_ id: String, _ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[id] = clean.isEmpty ? nil : clean
        persist()
    }

    /// notes.txt in the export
    func notesReport() -> String {
        var out = "Owner notes · CorckieApp \(AppInfo.versionLine) · \(Date().formatted())\n"
        for item in CheckList.all {
            if let note = notes[item.id] { out += "\n\(item.id) \(item.title) [\(status(item.id).icon)]\n\(note)\n" }
        }
        return notes.isEmpty ? out + "\n(no notes)\n" : out
    }

    struct TodoGroup: Identifiable {
        let place: CheckGuide.Place
        let items: [CheckItem]
        var id: String { place.rawValue }
    }

    /// The To do list: everything ⏳ or ❌, by where it's done.
    func todo() -> [TodoGroup] {
        CheckGuide.Place.allCases.compactMap { place -> TodoGroup? in
            let items = CheckList.all.filter { CheckGuide.of($0.id).place == place && [CheckStatus.pending, .fail].contains(status($0.id)) }
            return items.isEmpty ? nil : TodoGroup(place: place, items: items)
        }
    }

    func status(_ id: String) -> CheckStatus { entries[id]?.status ?? .pending }
    func note(_ id: String) -> String { entries[id]?.note ?? "" }

    func set(_ id: String, _ status: CheckStatus, _ note: String = "") {
        if let current = entries[id], current.status == status, current.note == note { return }
        entries[id] = Entry(status: status, note: note, date: Date())
        persist()
    }

    /// Sets only if not passed yet (automatic checks keep their first pass).
    func passOnce(_ id: String, _ note: String) {
        if status(id) != .pass { set(id, .pass, note) }
    }

    func reset(_ id: String) {
        entries[id] = nil
        persist()
    }

    func counts() -> (pass: Int, fail: Int, info: Int, pending: Int) {
        let s = CheckList.all.map { status($0.id) }
        return (s.filter { $0 == .pass }.count, s.filter { $0 == .fail }.count,
                s.filter { $0 == .info }.count, s.filter { $0 == .pending }.count)
    }

    func report() -> String {
        let c = counts()
        var out = "CorckieApp \(AppInfo.versionLine) · \(AppInfo.bundleID) · checks · \(Date().formatted())\n"
        out += "✅ \(c.pass)  ❌ \(c.fail)  ℹ️ \(c.info)  ⏳ \(c.pending)\n"
        for group in CheckList.groups {
            out += "\n\(group)\n"
            for item in CheckList.all where item.group == group {
                out += "\(status(item.id).icon) \(item.id) \(item.title)"
                if let e = entries[item.id] {
                    if !e.note.isEmpty { out += " — \(e.note)" }
                    out += " (\(e.date.formatted(date: .abbreviated, time: .shortened)))"
                }
                out += "\n"
                if let note = notes[item.id] { out += "    Note: \(note)\n" }
            }
        }
        return out
    }
}
