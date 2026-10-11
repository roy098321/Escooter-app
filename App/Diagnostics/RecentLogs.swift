import Foundation

/// T-00: the last 15 minutes of logs (error log incl. engine / recorder decisions, Bluetooth events), put in every
/// export so "Report a problem" needs no extra step.
enum RecentLogs {
    static func text(now: Date = Date(), minutes: Int = 15) -> String {
        let since = now.addingTimeInterval(-Double(minutes) * 60)
        var out = "Last \(minutes) minutes · \(now.formatted())\n\n== Error log, engine and recorder decisions ==\n"
        let entries = ErrorLog.shared.recent.filter { $0.at >= since }
        out += entries.isEmpty ? "(nothing)\n" : entries.map(\.line).joined(separator: "\n") + "\n"
        out += "\n== Bluetooth events ==\n"
        let events = AppModel.shared.scooter.timedEvents.filter { $0.at >= since }
        out += events.isEmpty ? "(nothing)\n" : events.map(\.line).joined(separator: "\n") + "\n"
        return out
    }
}
