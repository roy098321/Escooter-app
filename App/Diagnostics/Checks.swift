import Foundation
import Observation

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
    case none, scooter, sensors, simulator, backup, crash, outside, readability, results
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
        CheckItem(id: "a1", group: install, title: "Installs and opens", how: "Install with SideStore, open the app",
                  expected: "Marks itself on first open", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "a2", group: install, title: "Name and icon on the Home Screen", how: "Look at the Home Screen",
                  expected: "Scooter icon; name \"CorckieApp\" in full", needsScooter: false, manual: true, tool: .none),
        CheckItem(id: "a7", group: install, title: "v1 label visible on every screen", how: "Look at the bottom-right corner on every tab, pushed screen, sheet and Developer screen",
                  expected: "Small \"v1 · 0.4 (build)\" label, never covering anything", needsScooter: false, manual: true, tool: .none),
        CheckItem(id: "a3", group: install, title: "Permanent app ID", how: "Nothing to do",
                  expected: "com.corckieapp.app", needsScooter: false, manual: false, tool: .none),
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
        CheckItem(id: "b6", group: scooter, title: "Autostart traps (T14)", how: "Scooter screen → Traps: Record, walk it ~50 m switched on, spin the wheel on the stand, kick-start, Stop",
                  expected: "Recorded for Claude", needsScooter: true, manual: false, tool: .scooter),
        CheckItem(id: "b7", group: scooter, title: "Battery label (13 / 16 Ah)", how: "Read the label under the deck, pick it on the Scooter screen",
                  expected: "16 Ah expected", needsScooter: true, manual: false, tool: .scooter),

        CheckItem(id: "c1", group: background, title: "Wakes when the scooter turns on", how: "Scooter off · Home Screen (don't swipe the app away) · lock the phone · scooter on · wait 30 s",
                  expected: "Connected while in the background", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "c2", group: background, title: "Scooter data while locked", how: "Keep the phone locked ~1 min after the wake-up",
                  expected: "100+ packets while locked", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "c3", group: background, title: "Location while locked", how: "Starts with the wake-up (or Sensors → Start), lock, walk ~2 min",
                  expected: "20+ fixes while locked", needsScooter: false, manual: false, tool: .sensors),
        CheckItem(id: "c4", group: background, title: "Barometer while locked", how: "Same recording as location",
                  expected: "20+ readings while locked", needsScooter: false, manual: false, tool: .sensors),

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

        CheckItem(id: "e1", group: outside, title: "Fuel price (Ministry of Energy)", how: "Developer → Outside data → Run all",
                  expected: "95-octane price for this month, ILS/litre", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e2", group: outside, title: "Holidays (Hebcal)", how: "Same",
                  expected: "This year's Israeli holidays", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e3", group: outside, title: "Weather forecast (Open-Meteo)", how: "Same",
                  expected: "Hourly wind, gusts, rain, temperature", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e4", group: outside, title: "Backup forecast (MET Norway)", how: "Same",
                  expected: "Hourly wind, rain, temperature", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e5", group: outside, title: "Weather history (Open-Meteo)", how: "Same",
                  expected: "Yesterday's hourly wind and rain", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e6", group: outside, title: "Map elevation (Open-Meteo DEM)", how: "Same",
                  expected: "Elevation in metres", needsScooter: false, manual: false, tool: .outside),
        CheckItem(id: "e7", group: outside, title: "Replay map tiles (CARTO, OSM)", how: "Same",
                  expected: "A map tile image from each", needsScooter: false, manual: false, tool: .outside),

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

    private init() {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func status(_ id: String) -> CheckStatus { entries[id]?.status ?? .pending }
    func note(_ id: String) -> String { entries[id]?.note ?? "" }

    func set(_ id: String, _ status: CheckStatus, _ note: String = "") {
        if let current = entries[id], current.status == status, current.note == note { return }
        entries[id] = Entry(status: status, note: note, date: Date())
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    /// Sets only if not passed yet (automatic checks keep their first pass).
    func passOnce(_ id: String, _ note: String) {
        if status(id) != .pass { set(id, .pass, note) }
    }

    func reset(_ id: String) {
        entries[id] = nil
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
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
            }
        }
        return out
    }
}
