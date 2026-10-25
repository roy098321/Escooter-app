import Foundation

/// F-36 (owner 22 Oct, note 5): the "Scooter on" notification carries the quick-dial places as buttons (long-press: Uni · Home · Grandma · ?),
/// so one tap sets the destination before moving, without opening the app. Missed it: fix it at a stop on the ride screen (F-35).
/// F-39 leftover: after a trip that did not arrive, "↻ Continue to <place>" is the FIRST button.
/// Rejected: "Riding to Uni?" suggestions from habits (the app does not learn when or where the rider rides).
public enum ScooterOnActions {
    public static let categoryId = "corckie.scooterOn"
    /// iOS shows at most this many buttons comfortably under a notification
    public static let maxActions = 4
    static let prefix = "dest:"
    static let noneId = "dest:none"
    static let continuePrefix = "dest:continue:"

    public struct Action: Equatable, Sendable {
        public var id: String
        public var title: String
    }

    public struct Place: Equatable, Sendable {
        /// the key the Where to? choice uses ("place:<id>" or a saved route's id)
        public var key: String
        public var name: String
        /// the saved place behind the key (a route's end place), so one place never gets two buttons
        public var placeId: String?

        public init(key: String, name: String, placeId: String? = nil) {
            self.key = key
            self.name = name
            self.placeId = placeId
        }
    }

    /// The buttons in order: "↻ Continue to …" first when a trip is open, then the places (each once; the Continue place is not repeated),
    /// then "No destination" (the "?" of the quick dial), at most `maxActions` in all.
    public static func actions(continueTo: Place?, continueTitle: String? = nil, places: [Place]) -> [Action] {
        var out: [Action] = []
        if let c = continueTo { out.append(Action(id: continuePrefix + c.key, title: continueTitle ?? "\u{21BB} Continue to \(c.name)")) }
        var seen = Set<String>()
        if let c = continueTo { seen.insert(c.placeId ?? c.key) }
        for p in places where !p.name.isEmpty && out.count < maxActions - 1 && seen.insert(p.placeId ?? p.key).inserted {
            out.append(Action(id: prefix + p.key, title: p.name))
        }
        out.append(Action(id: noneId, title: QuickDialSlot.freeRideName))
        return out
    }

    public enum Choice: Equatable, Sendable {
        case destination(String)
        case noDestination
        case continueTrip(String)
    }

    /// The button the rider tapped (nil = not one of these, e.g. a plain tap on the notification)
    public static func choice(actionId: String) -> Choice? {
        if actionId == noneId { return .noDestination }
        if actionId.hasPrefix(continuePrefix) {
            let key = String(actionId.dropFirst(continuePrefix.count))
            return key.isEmpty ? nil : .continueTrip(key)
        }
        guard actionId.hasPrefix(prefix) else { return nil }
        let key = String(actionId.dropFirst(prefix.count))
        return key.isEmpty ? nil : .destination(key)
    }
}
