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
    case none, scooter, sensors, simulator, backup, crash, outside, readability, results, permissions, insights
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
    /// M1-16: the on-device M1 build's own groups (M1_PLAN section 4.1 to 4.3)
    static let simM = "M1 · simulator, no scooter"
    static let homeM = "M1 · scooter at home"
    static let ridesM = "M1 · real rides"
    /// M2: the routes build's checks (M2_PLAN section 4); they ride in the same list and the same results key
    static let routesM = "M2 · routes"
    /// M3: battery + scooter (M3_PLAN section 4)
    static let batteryM = "M3 · battery + scooter"
    /// M4: insights + stats (M4_PLAN section 5)
    static let insightsM = "M4 · insights + stats"

    static let groups = [install, scooter, background, phone, outside, ride, simM, homeM, ridesM, routesM, batteryM, insightsM, send]

    /// The P4 list, kept as it was: every P4 result stays readable under the same ID.
    static let p4: [CheckItem] = [
        CheckItem(id: "h1", group: install, title: "Permissions", how: "Developer → Permissions: allow everything; Location must be \"Always\"",
                  expected: "Location Always, Notifications, Motion, Bluetooth all allowed", needsScooter: false, manual: false, tool: .permissions),
        CheckItem(id: "h2", group: install, title: "Notification sounds on", how: "Developer → Permissions → step 6 (Sounds on)",
                  expected: "Sounds: on (needed for the Kick-off chime)", needsScooter: false, manual: false, tool: .permissions),
        CheckItem(id: "a1", group: install, title: "Installs and opens", how: "Install with SideStore, open the app",
                  expected: "Marks itself on first open", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "a2", group: install, title: "Name and icon on the Home Screen", how: "Look at the Home Screen",
                  expected: "Scooter icon; name \"CorckieApp\" in full", needsScooter: false, manual: true, tool: .none),
        CheckItem(id: "a7", group: install, title: "v1 label visible on every screen", how: "Look at the bottom-right corner on every tab, pushed screen, sheet and Developer screen",
                  expected: "Small \"v1 · 0.6 (build)\" label, never covering anything", needsScooter: false, manual: true, tool: .none),
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
                  expected: "\"Scooter on · 91%\" with \"Going for a ride? Tap here\" arrives, once per power-on (tap it too)", needsScooter: true, manual: false, tool: .sensors),
        CheckItem(id: "c6b", group: background, title: "Kick-off chime heard (ringer on)", how: "Ringer on · do the c6 steps · listen",
                  expected: "The Kick-off chime plays with the notification", needsScooter: true, manual: true, tool: .sensors),
        CheckItem(id: "c6d", group: background, title: "Notification clears when the scooter switches off", how: "Do the c6 steps · then switch the scooter off (or leave it ~5 min until it switches itself off)",
                  expected: "The \"Going for a ride?\" notification disappears (within ~2 min; at the latest when you open the app)", needsScooter: true, manual: true, tool: .sensors),
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
        CheckItem(id: "u2", group: phone, title: "Version 0.6 and thresholds (M1-01)", how: "Nothing to do · Run all automatic also marks it",
                  expected: "Version 0.6; speed warning on above 45 km/h, off below 43 (T99); safety margin +10% (T101)", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u3", group: phone, title: "Fake scooter replays phone GPS + barometer (M1-02)", how: "Nothing to do · Run all automatic marks it",
                  expected: "The ride-2 phone track lines up with the scooter samples (≤ 5 m); GPS and barometer replay on the same clock", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u4", group: phone, title: "Ride storage (M1-08)", how: "Nothing to do · Run all automatic marks it",
                  expected: "A test ride with samples, raw chunk, gap and stop is written, read back and deleted in a temporary database; your real rides are unchanged", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u5", group: phone, title: "Ride numbers from stored samples (M1-06)", how: "Nothing to do · Run all automatic marks it",
                  expected: "Ride 1 gives 437 Wh and 16.3 km, ride 2 gives 322 Wh and 13.7 km (±3% energy), top speed, peak temperature and time computed from one sample every 5 s", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u6", group: phone, title: "Live view rules and banner budget (M1-07)", how: "Nothing to do · Run all automatic marks it",
                  expected: "SLOW above 45, clears below 43 (scooter and GPS); GPS speed labelled; banners locked from 5 km/h; 2 at ride start; hot once, very hot until it cools; one \"Going for a ride?\" per power-on", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u7", group: phone, title: "\"Going for a ride?\" rules and message log (M1-10)", how: "Nothing to do · Run all automatic marks it",
                  expected: "One notification per power-on across 3 reconnect blips, removed at ride start and at scooter off, sent at night, never with the app open; every decision stored in the message log of a temporary database", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u8", group: phone, title: "Rides list rules (M1-14)", how: "Nothing to do · Run all automatic marks it",
                  expected: "Newest ride under Latest, other rides grouped by day, short hop kept apart, discarded hidden, date filter and delete work on made-up rides in a temporary database", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u9", group: phone, title: "Ride start and autostart traps (M1-03)", how: "Nothing to do · Run all automatic marks it",
                  expected: "On the fake scooter: walking the scooter is cancelled or trimmed away, a spinning wheel is cancelled within 20 s, a kick-start is confirmed by the motor current; Start ride skips the confirm step; Not riding cancels silently", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u10", group: phone, title: "Ride end, stops, pushing, Same ride, recovery (M1-04)", how: "Nothing to do · Run all automatic marks it",
                  expected: "On the fake scooter: dropped while standing ends after 30 s, 0x80 ends at once, auto-off and 10 min standstill end the ride, end time = last movement; pushing 1 km is a walking stretch with \"battery ran out at 3%\"; Same ride offered after a switch-off at a light; a relaunch mid-ride resumes, > 2 min recovers", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u11", group: phone, title: "Phone takeover and speed warning (M1-05)", how: "Nothing to do · Run all automatic marks it",
                  expected: "On the fake scooter: a 1-s link drop changes nothing; after ~5 s the phone takes over (GPS speed labelled, \"~N% est.\"), scooter numbers and odometer distance back on reconnect; SLOW above 45, clears below 43 on scooter and on GPS speed, no flicker", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u12", group: phone, title: "Recorder end to end (M1-09)", how: "Nothing to do · Run all automatic marks it (~10 s)",
                  expected: "Rides 1 and 2 through the Recorder into a temporary database: 437 Wh / 16.3 km and 322 Wh / 13.7 km, samples and raw packets stored; a kill mid-ride is recovered; your real rides unchanged", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u16", group: phone, title: "Backup writer (M1-16)", how: "Nothing to do · Run all automatic marks it",
                  expected: "A full backup and a ride file are written to a temporary folder and read back (compression, check sum, database header, ride id); latest.json is there; only the newest three full backups stay", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u15", group: phone, title: "Ride summary (M1-13)", how: "Nothing to do · Run all automatic marks it. Then open a ride in Rides to look at it (a simulated ride shows the same screen)",
                  expected: "A made-up ride stored in a temporary database gives the right time, distance, average speed and battery; the path has a dashed phone stretch and a walking stretch; the notes say recovered, phone stretch, heat and on foot; a ride without GPS shows the No GPS card; delete removes the ride and its readings", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u14", group: phone, title: "Live ride screen rules (M1-12)", how: "Nothing to do · Run all automatic marks it",
                  expected: "Ready has no clock or stop button and can be closed; a ride has no close button, only the held stop button (1 s); SLOW above 45, off below 43; GPS speed greyed and labelled, ~N% est.; one banner at a time, locked from 5 km/h; No GPS after 10 s", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "u13", group: phone, title: "Home states and connect rules (M1-11)", how: "Nothing to do · Run all automatic marks it",
                  expected: "First use and not connected show Connect your scooter (never Start ride); connected shows Start ride; a connect that fails shows Can't find the scooter after 30 s; a ride shows Ride in progress", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "o1", group: phone, title: "Onboarding in 3 presses (M1-11)", how: "Developer → Show onboarding (the scooter stays paired), go through it",
                  expected: "Done in 3 presses or fewer; ends on Home", needsScooter: false, manual: false, tool: .none),
        CheckItem(id: "d7", group: phone, title: "Simulated disconnect (phone takes over)", how: "Simulated scooter → Fault \"D7 · Disconnect at 40%\" → 50× → Start",
                  expected: "GPS speed shown (labelled) during the gap; totals stay scooter-only", needsScooter: false, manual: false, tool: .simulator),
        CheckItem(id: "d8", group: phone, title: "Simulator keeps real data apart", how: "Any simulator run",
                  expected: "Real database ride count unchanged", needsScooter: false, manual: false, tool: .simulator),
        CheckItem(id: "d11", group: phone, title: "Simulator drives the real screens (M1-15)", how: "Simulated scooter → Run on the real screens → pick a ride + speed → Start",
                  expected: "SIMULATED banner on Home, the live view and the summary; the ride appears in Rides; real Rides unchanged after End simulation", needsScooter: false, manual: true, tool: .simulator),
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
        CheckItem(id: "q1", group: ride, title: "Phone battery per ride (M1-16)", how: "Nothing to do · ride 15 minutes or more with the phone not charging",
                  expected: "At most 10% of phone battery per 30 min of riding; the note gives the % per ride and per 30 min", needsScooter: true, manual: false, tool: .none),
        CheckItem(id: "d10", group: ride, title: "Backup written after a real ride (M1-16)", how: "Pick the backup folder first (Developer → Backup folder), then finish a ride",
                  expected: "A ride file appears in CorckieApp Backup/rides in your folder, and Settings → Last backup shows the time", needsScooter: true, manual: false, tool: .none),

        CheckItem(id: "g1", group: send, title: "Export to Claude", how: "Developer → Results → Prepare export → Share",
                  expected: "One .zip: results, error log, Bluetooth events, raw packets", needsScooter: false, manual: false, tool: .results)
    ]

    /// M1-16: the whole M1_PLAN section 4 list = the P4 list + the checks the plan adds (no ID twice).
    /// The plan's e1-e5 and b9 got an "m" ID (e1m...) because P4 already used e1-e5 and b9 for other checks.
    static let m1: [CheckItem] = {
        var list = p4
        let at = list.firstIndex { $0.id == "g1" } ?? list.count
        list.insert(contentsOf: m1New, at: at)
        list.insert(contentsOf: m2New, at: list.firstIndex { $0.id == "g1" } ?? list.count)
        list.insert(contentsOf: m4New, at: list.firstIndex { $0.id == "g1" } ?? list.count)
        return list
    }()

    static let all: [CheckItem] = m1

    private static func m(_ id: String, _ group: String, _ title: String, _ how: String, _ expected: String,
                          scooter: Bool = false, manual: Bool = false, tool: CheckTool = .none) -> CheckItem {
        CheckItem(id: id, group: group, title: title, how: how, expected: expected, needsScooter: scooter, manual: manual, tool: tool)
    }

    private static let simStart = "Developer → Simulated scooter → Run on the real screens → "
    private static let m1New: [CheckItem] = [
        m("a8", simM, "Expiry reminder scheduled", "Nothing to do", "A reminder is pending for 1 day before the app expires", manual: true),
        m("w1", simM, "Speed warning turns on above 45", simStart + "Scenario SPD-46 · 5× · Start", "Tile red + SLOW within 1 s of passing 45 km/h", manual: true, tool: .simulator),
        m("w2", simM, "Warning clears below 43, no flicker", "Same run as w1 (46 → 44 → 46 → 42)", "Still red at 44, clears at 42; one on / off per crossing", manual: true, tool: .simulator),
        m("w3", simM, "Warning on GPS speed in phone mode", simStart + "Scenario SPD-46-GPS · 5× · Start", "Red + SLOW with the GPS label while disconnected", manual: true, tool: .simulator),
        m("p1", simM, "Phone takeover on screen", simStart + "Scenario D7 · 50× · Start", "GPS speed greyed, ~N% est., dashed path, banner; scooter numbers back on reconnect", manual: true, tool: .simulator),
        m("p2", simM, "Data format changed", simStart + "Scenario SC-04 · 50× · Start", "Banner Scooter data format changed, phone mode, raw packets still stored", manual: true, tool: .simulator),
        m("l1", simM, "GPS lost", simStart + "Scenario SC-07 · 5× · Start", "No GPS chip after 10 s, dot frozen grey, distance keeps counting", manual: true, tool: .simulator),
        m("l2", simM, "No internet", "Airplane mode on → " + simStart + "Ride 2 · 50× · Start → airplane mode off", "Offline map chip, ride completes, no crash", manual: true, tool: .simulator),
        m("l3", simM, "Safety: no tabs, banners locked while moving", "During a simulated ride try to reach a tab, swipe down, tap a banner above 5 km/h", "No tabs or navigation; banner taps do nothing while moving", manual: true, tool: .simulator),
        m("l4", simM, "Heat banner", simStart + "Ride 1 · 50×", "Scooter hot, 90 degrees once; never two banners at once", manual: true, tool: .simulator),
        m("e1m", simM, "End rules", simStart + "Scenarios SC-02, T8, Standstill 10 min · 50× each", "Ends by A, A2 at once (scooterOff), C (standstill); clock stops at the last movement", manual: true, tool: .simulator),
        m("e4m", simM, "Crash mid-ride recovery", "Simulated ride → Developer → Crash during simulated ride → open the app again", "Ride recovered, ended at its last sample, 5 s lost at most", manual: true, tool: .simulator),
        m("e5m", simM, "Phone battery low modes", simStart + "Scenario SC-13 · 50×", "GPS reduced at 19%, off at 9% with the Phone battery low banner", manual: true, tool: .simulator),
        m("s9", simM, "Plausibility", simStart + "Scenario SC-15 · 50×", "Spikes dropped; info shows Some scooter readings were ignored", manual: true, tool: .simulator),
        m("s8", simM, "Ride without GPS", simStart + "Scenario F1 P2 session · 50×", "Summary shows No GPS on this ride; stats complete", manual: true, tool: .simulator),
        m("k4", simM, "Untracked km", simStart + "Scenario SC-06", "Home card 3.2 km ridden without the phone; not in rides", manual: true, tool: .simulator),
        m("r1", simM, "Rides list layout", "After two simulated rides open Rides", "Grouped by day, Latest on top, short hop in its own section", manual: true),
        m("r2", simM, "Filter and empty states", "Rides → filter Today, then a date with no rides", "Matching rides; then No rides match · Clear filters", manual: true),
        m("r3", simM, "Open and delete", "Tap a simulated ride → detail → Delete → confirm", "Detail opens; ride gone after confirming; cancel keeps it", manual: true),

        m("k1", homeM, "Home when connected", "Scooter on, open the app on Home", "Status card with battery %, Start ride button", scooter: true, manual: true),
        m("k2", homeM, "Home when not connected", "Scooter off, look at Home", "Amber Connect your scooter, not connected · last seen, no Start ride", scooter: true, manual: true),
        m("k3", homeM, "Connect fails after 30 s", "Scooter off → tap Connect your scooter → wait", "Can't find the scooter · Is it switched on? + Try again after 30 s", scooter: true, manual: true),
        m("n1", homeM, "Going for a ride? arrives", "App in the background, phone locked · scooter off, then on", "Silent notification Scooter on · N% within 30 s", scooter: true, manual: true),
        m("n2", homeM, "Tapping it opens the live view", "Tap the notification from n1", "Live view in Ready; no ride until the wheel moves", scooter: true, manual: true),
        m("n3", homeM, "Not sent while the app is on screen", "App open on Home · scooter off, then on", "No notification", scooter: true, manual: true),
        m("n4", homeM, "Removed when the scooter turns off", "After n1 switch the scooter off without riding", "Notification gone", scooter: true, manual: true),
        m("n5", homeM, "Once per power-on", "Scooter on, app in the background, leave it 5 min", "One notification only; off / on later sends a new one", scooter: true, manual: true),
        m("l5", homeM, "Start ride by hand", "Scooter on, standing → Home → Start ride → hold to end after ~20 s", "Live view without starting…; held end; piece under 0.5 km discarded", scooter: true, manual: true),
        m("l6", homeM, "Hold to end, not a tap", "Start ride → tap the stop button once → then hold ~1 s", "Tap does nothing; hold ends the ride", scooter: true, manual: true),
        m("l7", homeM, "Not riding", "Developer → Trap test → arm roll · roll the scooter by hand · tap Not riding", "Ride cancelled silently, back on Home, no ride row", scooter: true, manual: true),
        m("l8", homeM, "App Shortcut Start ride", "Scooter on · Shortcuts or Siri → Start ride in CorckieApp → hold to end", "Ride started by the shortcut while connected", scooter: true, manual: true),
        m("t1", homeM, "Autostart trap: walking", "Trap test → arm walk · walk the scooter switched on ~50 m", "Cancelled silently, or the walk trimmed from the ride", scooter: true, manual: true),
        m("t2", homeM, "Autostart trap: wheel spin", "Arm spin · scooter on its stand, spin the wheel ~10 s", "Cancelled silently; no ride row", scooter: true, manual: true),
        m("t3", homeM, "Autostart trap: kick-start", "Arm kick · kick off and ride ~100 m", "Ride starts and confirms; records which signal confirmed", scooter: true, manual: true),

        m("x1", ridesM, "A real commute, end to end", "Phone locked · ride as usual · don't touch the phone", "Started by autostart, 95% of seconds sampled, ended by a rule", scooter: true),
        m("x2", ridesM, "Two rides in a day", "Ride home the same day", "Both under today, Latest on top", scooter: true),
        m("s1", ridesM, "Summary opens, closes to Home", "Open the app after a ride", "Summary opens by itself; closing goes to Home", scooter: true, manual: true),
        m("s2", ridesM, "Summary numbers recorded", "Nothing to do", "Time, distance, average speed, battery used, top speed recorded", scooter: true),
        m("s3", ridesM, "Distance matches the odometer bytes", "Nothing to do", "Speed integrated over the ride within 3% of the odometer distance", scooter: true),
        m("s4", ridesM, "Summary vs the scooter's own display", "Read odometer and battery on the scooter before and after; compare with summary info", "Odometer difference = summary distance ± 0.1 km; battery matches ± 1", scooter: true, manual: true),
        m("s5", ridesM, "First-ride card", "Your first real M1 ride", "Your first ride is in card", scooter: true),
        m("s6", ridesM, "Map, chart and scooter group look right", "Look at a summary", "Path coloured by speed; chart readable; no records or celebrations", scooter: true, manual: true),
        m("p3", ridesM, "Phone takeover: out of range and back", "Mid-ride stop, lock the phone, walk away until the scooter drops, walk back within 30 s, ride on", "Banner + GPS speed while away; reconnects by itself; gap row; distance filled from the odometer", scooter: true, manual: true),
        m("p4", ridesM, "Phone takeover: out of range and stop", "At the end of a ride leave the scooter on, walk away, stand still ~1 min", "Phone mode, then the ride ends; end time = last riding movement", scooter: true, manual: true),
        m("e2m", ridesM, "Scooter off ends the ride at once", "At the end of a ride switch the scooter off", "Ride ends at once, end reason scooter switched off", scooter: true),
        m("e3m", ridesM, "Same ride", "Mid-commute switch off at a stop, set off again within 10 min", "Same ride? banner; Yes joins the two pieces", scooter: true),
        m("w4", ridesM, "Speed warning on real rides", "Nothing to do", "Times red, seconds red, top speed per ride (for tuning)", scooter: true),
        m("b9m", ridesM, "Link over a ride", "Nothing to do", "Disconnects per ride and their reasons", scooter: true)
    ]

    private static let routeSim = "Developer → Simulated scooter → Run on the real screens → "
    /// M2_PLAN section 4. Entries are added as their task is built (the ID list there is the full list).
    private static let m2New: [CheckItem] = [
        m("u17", phone, "Places, matching, Save as route (M2-01)", "Nothing to do · Run all automatic marks it",
          "Tolerance 100 m to 1 km; the 2nd trip suggests a route; parked 120 m away still matches; a loop, a ride with no GPS and a dismissed trip never make a suggestion"),
        m("u18", phone, "Variants and street names (M2-02)", "Nothing to do · Run all automatic marks it",
          "A detour is a new variant; a street name from the phone replaces Variant 2, an owner name stays; the way back is its own route"),
        m("u19", phone, "Usual ranges and Today estimate (M2-03)", "Nothing to do · Run all automatic marks it",
          "Middle 80% of the last 20 rides in 90 days; under 5 rides min to max; gates 3 / 5 rides; noticeably different at 1 min or 2%; Today shown honest, the needed battery carries the 10% margin"),
        m("u20", phone, "Route card and Routes list (M2-04)", "Nothing to do · Run all automatic marks it",
          "Title, six ranges, Today strip, variants + map, elevation both ways, rides list and the Routes list are built right from stored rides"),
        m("u21", phone, "Greying with the safety margin (M2-05)", "Nothing to do · Run all automatic marks it",
          "Exactly at the limit fits; 0.1% under is greyed; One way only, Tight and fits at the 10% spare edge; no data = no chip; last seen shows its age; I can charge here lifts the way back"),
        m("u22", phone, "Where to? and arrival time (M2-06)", "Nothing to do · Run all automatic marks it",
          "The chip appears only once a route is saved; arrival time on pace, running late (blended by km done), off the route (distance / typical speed); the display changes at most every 30 s or at a 1 min jump"),
        m("u23", phone, "Arrive by and the leave reminder (M2-07)", "Nothing to do · Run all automatic marks it",
          "Leave = target - today - margin (upper edge minus median), settled in at most 3 steps across the rush-hour boundary; under 3 rides says so; the reminder is held to 07:00 or dropped in quiet hours and replaced only when 2 min or more earlier"),
        m("u24", phone, "Dot follows the route without GPS (M2-08)", "Nothing to do · Run all automatic marks it",
          "GPS lost on a known route: the hollow dot moves by wheel distance and is within 30 m after 2 km; off the route it stays frozen and grey"),
        m("u25", phone, "There and back and the ride-start warning (M2-09)", "Nothing to do · Run all automatic marks it",
          "Round trip with a 10% margin and a 5% reserve: fits at 10% spare, tight below, not for the way back, not even there; I can charge here lifts the way back; the warning at ride start comes once and only when it does not fit"),
        m("d12", routesM, "Simulated routes never touch real routes (M2-01)", "Checked after every simulator run", "Real place, route and variant counts unchanged", tool: .simulator),
        m("q2", routesM, "Route processing is quick (M2-01)", "Nothing to do · it measures every ride", "Milliseconds for matching one ride are in the note (a ride close must stay fast)"),
        m("rt1", routesM, "Save as route? after 2 commutes", routeSim + "Scenario ROUTE-COMMUTE · 50× · Start; open the 2nd summary",
          "After trip 2 the summary shows Save as route?; Save makes it a route; trip 3 joins it", manual: true, tool: .simulator),
        m("rt2", routesM, "Not a route is remembered", "Same run → Not a route on the 2nd summary → run the scenario again", "The card does not come back for this trip", manual: true, tool: .simulator),
        m("rt3", routesM, "A loop and a ride with no GPS are never offered", "Scenarios ROUTE-LOOP and ROUTE-NOGPS · 50×", "No Save as route? card", manual: true, tool: .simulator),
        m("rt4", routesM, "A detour becomes a variant", routeSim + "Scenario ROUTE-VARIANT · 50× → Routes → the route", "Two variants, the second named Variant 2 (the fake map has no streets)", manual: true, tool: .simulator),
        m("rt5", routesM, "Street names offline", "Airplane mode on → Scenario ROUTE-VARIANT · 50×", "Variant 2 stays, nothing crashes, nothing waits", manual: true, tool: .simulator),
        m("rt6", routesM, "There and back are two routes", routeSim + "Scenario ROUTE-THEREBACK · 50× → Routes", "A to B and B to A listed separately", manual: true, tool: .simulator),
        m("rt7", routesM, "Route card reads right", routeSim + "Scenario ROUTE-COMMUTE-6 · 50× → Save the route → Routes tab → the route", "Title + based on 6 rides, six ranges, Today strip, map with the path, rides list; sections with no data are hidden", manual: true, tool: .simulator),
        m("rt8", routesM, "Routes list: saved, suggested, empty", "Routes tab with no rides, then after ROUTE-COMMUTE (before saving) and after saving", "Empty: No routes yet · Ride the same trip twice…; the suggestion sits under Suggested routes; saved routes show rides and ranges", manual: true, tool: .simulator),
        m("rt9", routesM, "Rename and remove a route", "Route card → ⋯ → Rename route; then Remove route", "The new name stays after reopening; a removed route is gone, its rides stay in Rides", manual: true, tool: .simulator),
        m("rt10", routesM, "Greyed route and chips", routeSim + "Scenario ROUTE-LOWBATT · 50× · save both routes on their 2nd summaries · after the run open Routes",
          "Route 2 (the way back) is greyed with Not enough battery, Route 1 has the amber chip One way only; both can still be opened", manual: true, tool: .simulator),
        m("rt11", routesM, "Where to? and the arrival strip", routeSim + "Scenario ROUTE-COMMUTE-6 · 5× · save the route on the 2nd summary · after the 3rd trip is over open Home, tap the chip, then watch the 4th trip's live screen",
          "The chip shows once a route is saved; the live screen says Route 1 · arrive ~HH:MM · N min left and counts down without jumping", manual: true, tool: .simulator),
        m("rt12", routesM, "The dot keeps moving without GPS", routeSim + "Scenario ROUTE-GPSLOSS · 5× · save the route on the 2nd summary · tap its Where to? chip on Home before the 4th trip",
          "On the 4th trip the dot turns hollow with the No GPS chip, keeps moving along the route and is solid again when GPS returns", manual: true, tool: .simulator),
        m("rt14", routesM, "Arrive by and the reminder", routeSim + "Scenario ROUTE-COMMUTE-6 · 50× · save the route · Routes → the route → Arrive by → pick a time about 40 min from now, switch Remind me on",
          "Leave by HH:MM with today's minutes + margin; the reminder line says set for HH:MM (or held to 07:00 in quiet hours); the reminder arrives on the lock screen at that time", manual: true, tool: .simulator),
        m("rt15", routesM, "There and back card and the ride-start warning", routeSim + "Scenario ROUTE-LOWBATT · 50× · save both routes on their 2nd summaries · wait for the end (battery 10%) → Home → Where to? → Route 1 → Start; then open the route",
          "The route card shows ❌ Not enough for the way back (or for the way there); at ride start one banner says the battery does not last for the way back, and it does not come again", manual: true, tool: .simulator),
        m("rt13", routesM, "A real route is learned", "Ride the same trip twice (any two real rides between the same two places)", "After ride 2 the summary offers Save as route?", scooter: true, manual: true),
        m("rt16", routesM, "Parking a little differently still matches", "Start the second trip 50–150 m from the first start", "Same route, not a new suggestion", scooter: true, manual: true),
        m("rt17", routesM, "A real detour is a variant named after the street", "Ride to the same place by another street (internet on)", "A second variant via the street, or Variant 2 when no street came back", scooter: true, manual: true),
        m("rt19", routesM, "Real arrival strip", "Home → Where to? → pick the route → Start → ride it", "Arrival time within about 2 min at the end; no jumping", scooter: true, manual: true),
        m("rt20", routesM, "Real GPS loss on a known route", "Ride a known route with Where to? set, through a tunnel or underpass", "The dot keeps moving hollow with No GPS and is right again afterwards", scooter: true, manual: true),
        m("u26", batteryM, "Maintenance by km (M3-06)", "Nothing to do · Run all automatic marks it",
          "Tyres (50 PSI), brakes and bolts count scooter km; due items are reminded once and again after 3 days; Mark done restarts the count; no reminder in quiet hours, after 2 a day or during a ride"),
        m("u27", batteryM, "Battery calibration from rides (M3-01)", "Nothing to do · Run all automatic marks it",
          "The three real rides give about 8.3 Wh per 1% (learning, 3 of 5); calibrated after 5 rides; short hops, gaps, simulated rides and outliers are left out; the line ends with this phone's calibration"),
        m("u28", batteryM, "Charge log, cycles, battery health (M3-02)", "Nothing to do · Run all automatic marks it",
          "A rested % jump between two rides is logged as a charge (+3 points or more; smaller rises and simulated rides ignored); cycles = the larger of charged and used; health only after 5 cycles and 20 rides; the sag rule uses the next start only when no charge is in between; the line ends with this phone's charge log"),
        m("u29", batteryM, "Real range and charge time (M3-03)", "Nothing to do · Run all automatic marks it",
          "Range = (current % - reserve) / my %/km over the last 10 rides (26 km from 64% at 2.3%/km); below 20% shown with ~; the 10% margin only in the decision range; charge time ~4.5 h from 40%, ~1 h from 85%, Full at 100%; the line ends with this phone's range"),
        m("mt3b", batteryM, "Battery page (M3-04)", "Scooter tab → Battery; also Home → tap the status card",
          "Range (honest, plus one line with the 10% safety margin), Charging (Full from now while connected), Calibration (Learning N of 5 / Calibrated, Wh per 1%), Charge log, Charge cycles, Health (Gathering data until 5 cycles and 20 rides). ui-shots: battery-page, battery-page-empty, battery-page-calibrated", manual: true),
        m("bt2", batteryM, "Real charge is found", "Ride, let the battery drop at least 10 points, rest 20 s, switch off, charge it for a while, then ride again and wait for the summary",
          "Battery page (Scooter tab → Battery) lists the charge with from % to %, and Run all automatic shows 1 or more charges at the end of u28's line", scooter: true, manual: true),
        m("bt1", batteryM, "Real calibration after real rides", "After at least 5 real rides that each used 10% or more (rest 20 s before switching off): Run all automatic, then read the end of u27's line",
          "This phone: about 7.5–9.5 Wh per 1% (750–950 Wh usable), calibrated on 5 or more rides, no Check battery calibration", scooter: true, manual: true),
        m("mt1", batteryM, "Maintenance screen and reminder", "Settings → Maintenance → look at the three rows, tap Mark done on Tyre pressure",
          "Tyre pressure (50 PSI), Brakes, Bolts and folding joint each show km left; Mark done on tyres resets it to 300 km left (after the first ride)", manual: true),
        m("mt2s", batteryM, "Scooter tab (M3-05)", "Open the Scooter tab; tap Maintenance; go back; tap Forget scooter and Cancel (confirm only if you want to pair again)",
          "Status shows Connected or Last seen + battery; Info shows model, firmware, odometer; Maintenance opens the same screen as Settings; Forget asks first and removes the pairing only (rides stay)", manual: true)
    ]

    /// M4 (M4_PLAN section 5): each task adds its checks with it.
    private static let m4New: [CheckItem] = [
        m("u30", insightsM, "Outside data cache and fallbacks (M4-01)", "Nothing to do · Run all automatic marks it",
          "Forecast cached 60 min, MET Norway when Open-Meteo is down, an old cache shown with its age and dropped after 24 h; weather history for past rides filled once, retried daily, the archive after 30 days; elevation cached forever; holidays offline then Hebcal; only a ~1 km cell is ever sent; the line ends with this phone's cache"),
        m("e9", insightsM, "The cache fills by itself", "Open the app online, wait about 30 s, then Developer → Outside data → look at Cache (M4-01)",
          "Weather hours (forecast), holidays for this and next year, and after a ride also history hours and elevation cells; the line under it says what the last refresh did", manual: true, tool: .outside),
        m("e10", insightsM, "Offline: the cache is used, nothing crashes", "Airplane mode on → Developer → Outside data → Refresh the cache now → airplane mode off",
          "Forecast shows its age (or No forecast), holidays say offline, History says waiting, no crash and no waiting for time-outs", manual: true, tool: .outside),
        m("e11", insightsM, "Weather history for a real ride", "After a real ride that ended more than an hour ago (internet on): Developer → Outside data → Refresh the cache now",
          "History: 1 filled (or cached) for the ride and the cache line shows history hours; Elevation shows new cells; the factors (M4-02) look the ride's weather up later", scooter: true, manual: true, tool: .outside),
        m("u31", insightsM, "Factors engine: wind, rain, day type, rush hour, load, effects with gates (M4-02)", "Nothing to do · Run all automatic marks it",
          "Made-up windy commute: headwind 12 / -12 km/h, dry, workday, rush hour filled per ride; headwind and rush-hour effects found within 10%; Yom Kippur counts as Saturday, its eve as Friday; 2 windy rides show only progress; rain pooled per km; pure noise shows nothing; weather missing waits; the line ends with this phone's factor cache"),
        m("mf1", insightsM, "Real rides get weather and a believable headwind", "After a real ride that ended more than an hour ago (internet on): Developer → Outside data → Refresh the cache now, then Rides → the ride → More info",
          "The Factors line shows headwind or tailwind in km/h, wind level, dry or wet, temperature, day type (and rush hour on a workday morning / evening); the headwind sign fits how the wind felt", scooter: true, manual: true),
        m("u32", insightsM, "Insight catalogue: gates, ranking, N more, Recent order (M4-03)", "Nothing to do · Run all automatic marks it",
          "Every catalogue row speaks with made-up numbers and none uses reward words; 2 windy rides give only a progress line, enough rides the card; class + size ranking with the freshness penalty; at most 2 at ride start in C24 order; Recent by time; the simulated windy week in a temporary database: progress line at 4 rides, tailwind credit at 24, no duplicate on a re-run, a late card goes to Recent only, the week card is built; the line ends with this phone's insight rows"),
        m("mi1", insightsM, "Simulated windy week: the right card after the ride, the progress line before the gate", "Developer → Insights → Simulated windy week · 4 rides, then · 24 rides",
          "4 rides: no top card, one progress line \"Headwind on Seed commute: 2 of 3 windy rides\"; 24 rides: a top card or N more with \"Tailwind saved you ~1.5 min …\", a week card; plain words, no records, streaks or praise", manual: true, tool: .insights),
        m("u33", insightsM, "Message budget: 2 a day, quiet hours, never during a ride, weekly Sunday 07:30, wind once a day (M4-04)", "Nothing to do · Run all automatic marks it",
          "Maintenance, the weekly summary and wind picking up share one budget: none during a ride, maintenance and wind dropped 22:00-07:00, 2 a day with the weekly one keeping its place, wind once a day, the weekly one at Sunday 07:30; every send and drop is in the message log with its reason; Going for a ride and Arrive by stay outside; the line ends with this phone's count"),
        m("mn1", insightsM, "The weekly notification arrives Sunday 07:30", "Ride on 2 different days in a week, then look at Sunday 07:30",
          "A notification \"Your week\" with \"Last week: N km, N rides, ...\" at 07:30; tapping it opens the app (Stats, that week, once the Stats tab exists)", manual: true),
        m("mn2", insightsM, "Wind picking up arrives once, only before a usual ride", "On a windy day, shortly before the time you usually ride a saved route (3+ rides on that weekday), internet and background refresh on",
          "One notification \"Wind picking up\" with how it changes the ride; none the same day again; none at night or during a ride", manual: true)
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
    /// M1-16: this build's results. The P4 results stay untouched under `p4Key` (read-only history, in the export).
    @ObservationIgnored private let key = "corckie.checkResults.m1"
    @ObservationIgnored private let p4Key = "corckie.checkResults.p4"
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
        } else if defaults.data(forKey: key) == nil, let old = p4Results() {
            // first start of the M1 build: carry the P4 results over (the P4 copy itself is never changed)
            saved = old
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

    private func p4Results() -> [String: Entry]? {
        guard let data = defaults.data(forKey: p4Key) else { return nil }
        return try? JSONDecoder().decode([String: Entry].self, from: data)
    }

    /// history.txt in the export: the P4 build's results exactly as stored (never written by this build)
    func p4HistoryReport() -> String {
        var out = "P4 check results (history, read-only) · \(Date().formatted())\n"
        guard let old = p4Results(), !old.isEmpty else { return out + "\n(none stored)\n" }
        for id in old.keys.sorted() {
            guard let e = old[id] else { continue }
            out += "\(e.status.icon) \(id)" + (e.note.isEmpty ? "" : " — \(e.note)")
            out += " (\(e.date.formatted(date: .abbreviated, time: .shortened)))\n"
        }
        return out
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
