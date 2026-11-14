import Foundation

/// D2 option C (revised 13 Nov): "New scooter week". Milestones that tick by themselves after Start fresh. Developer only;
/// no thumbs, no nudge on rider screens (P-10). Counted in rides, never times of day. Pure logic: the facts come from the database.
public enum NewScooterWeek {
    public struct Milestone: Equatable, Sendable {
        public let id: String
        public let title: String
        /// The ⓘ: what to look at
        public let lookAt: String
    }

    /// What the app has seen since Start fresh
    public struct Facts: Equatable, Sendable {
        public var startedFresh = false
        public var backupMade = false
        public var paired = false
        public var rides = 0
        public var routeSuggested = false
        public var bestRouteRides = 0
        public var calibrated = false
        public var weeklySummarySeen = false
        public var riderInfoBack = false
        public init() {}
    }

    public static let milestones: [Milestone] = [
        Milestone(id: "M0", title: "Fresh start", lookAt: "Did the backup land in Files?"),
        Milestone(id: "M1", title: "Pair", lookAt: "Pop-ups as the screens said? Does the km match the dashboard?"),
        Milestone(id: "M2", title: "Ride 1", lookAt: "First-ride card. Any number shown too early?"),
        Milestone(id: "M3", title: "Same trip twice", lookAt: "\"Save as route?\" and \"Where to?\" appear."),
        Milestone(id: "M4", title: "Route ride 3", lookAt: "Today estimate and arrival time make sense?"),
        Milestone(id: "M5", title: "Ride 5", lookAt: "Battery numbers feel right? Size = 16 Ah?"),
        Milestone(id: "M6", title: "Ride 10", lookAt: "Range and estimates trustworthy now?"),
        Milestone(id: "M7", title: "First Sunday", lookAt: "Was the weekly summary worth it with this little data?"),
        Milestone(id: "M8", title: "Rider info back", lookAt: "Old routes back, battery still new?"),
    ]

    public static func isDone(_ id: String, _ f: Facts) -> Bool {
        switch id {
        case "M0": return f.startedFresh
        case "M1": return f.paired
        case "M2": return f.rides >= 1
        case "M3": return f.routeSuggested
        case "M4": return f.bestRouteRides >= 3
        case "M5": return f.calibrated || f.rides >= 5
        case "M6": return f.rides >= 10
        case "M7": return f.weeklySummarySeen
        case "M8": return f.riderInfoBack
        default: return false
        }
    }

    /// The group is shown from Start fresh until the report is shared, or 30 days
    public static let lifetimeMs: Int64 = 30 * 86_400_000

    public static func isActive(startedAtMs: Int64?, sharedAtMs: Int64?, nowMs: Int64) -> Bool {
        guard let startedAtMs, sharedAtMs == nil else { return false }
        return nowMs - startedAtMs <= lifetimeMs
    }

    /// The week report: one short text to paste, milestones with their notes
    public static func report(_ f: Facts, notes: [String: String]) -> String {
        var lines = ["New scooter week"]
        for m in milestones {
            var line = "\(isDone(m.id, f) ? "done" : "waiting") \u{00B7} \(m.id) \(m.title)"
            if let note = notes[m.id], !note.isEmpty { line += " \u{00B7} \(note)" }
            lines.append(line)
        }
        lines.append("Rides since the fresh start: \(f.rides)")
        return lines.joined(separator: "\n")
    }
}
