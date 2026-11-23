import Foundation

// N10-13 / N10-19 / N10-20 / N10-21 (batch 10): one row per part for the Maintenance screen, the Scooter tab card, the tab dot
// and the Home line. A part with an open fault or a due reminder leaves the list into its own card at the top (red when it isn't
// safe to ride). Quiet rows show the next check in km; learning rows say how many rides are left. Never "OK", never a tick.

public struct PartRow: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        /// An open fault: red (not safe to ride) or amber
        case issue(red: Bool, faultId: String)
        /// A reminder has run out
        case due(reminderId: String)
        /// Nothing to do yet
        case quiet
        /// Still learning this part's normal
        case learning(ridesLeft: Int)
    }

    public var part: MaintPart
    public var state: State
    /// The line under the part name
    public var line: String
    /// The reminder behind this row (tap → reminder page), if any
    public var reminderId: String?

    public var id: String { part.rawValue }
    /// Shown as its own card at the top
    public var standsOut: Bool {
        switch state {
        case .issue, .due: return true
        default: return false
        }
    }
    public var isRed: Bool { if case .issue(let red, _) = state { return red } else { return false } }
}

/// A km reminder as the parts list sees it
public struct PartReminder: Equatable, Sendable {
    public var id: String
    public var part: MaintPart
    public var status: MaintenanceStatus
    public var name: String

    public init(id: String, part: MaintPart, status: MaintenanceStatus, name: String) {
        self.id = id
        self.part = part
        self.status = status
        self.name = name
    }

    /// The km reminders that exist today: tyres, brakes, bolts
    public static func part(forReminder id: String) -> MaintPart? {
        switch id {
        case "tyres": return .tyres
        case "brakes": return .brakes
        case "bolts": return .bolts
        default: return nil
        }
    }
}

public enum MaintParts {
    /// The order of the plain list (the Scooter tab card puts Battery first on its own wide tile)
    public static let order: [MaintPart] = [.battery, .brakes, .tyres, .motor, .bolts, .electrics]

    /// Rides still needed before a part's faults can speak (the largest of its faults, at most 10)
    public static func ridesLeft(_ book: FaultBook, scooterId: String, part: MaintPart) -> Int {
        let kinds = FaultKind.allCases.filter { $0.part == part && $0.needsLearning && !$0.atSwitchOn }
        guard !kinds.isEmpty else { return 0 }
        let counts = kinds.map { kind -> Int in
            // a part with variants (F1 per band, F5 per route) is learned once any variant is
            let prefix = FaultBook.key(scooterId, kind)
            let best = book.baselines.filter { $0.key == prefix || $0.key.hasPrefix(prefix + "|") }.map(\.value.samples.count).max() ?? 0
            return max(0, FaultGate.learnRides - best)
        }
        return counts.min() ?? 0
    }

    /// N11-1: the id a tyre-pressure (energy) hint row carries instead of a fault record's
    public static let energyHintId = "energy-hint"

    /// `hints` (N11-1): the energy hint's line per lit part; an open fault on that part wins
    public static func rows(open: [FaultRecord], reminders: [PartReminder], ridesLeft: [MaintPart: Int],
                            batteryLine: String?, hints: [MaintPart: String] = [:]) -> [PartRow] {
        var rows: [PartRow] = []
        for part in order {
            let reminder = reminders.first { $0.part == part }
            if let f = open.filter({ $0.kind.part == part && $0.status == .open }).max(by: { $0.kind.level < $1.kind.level }) {
                rows.append(PartRow(part: part, state: .issue(red: f.kind.level == .red, faultId: f.id),
                                    line: FaultCopy.text(f.kind).row, reminderId: reminder?.id))
            } else if let hint = hints[part] {
                rows.append(PartRow(part: part, state: .issue(red: false, faultId: energyHintId), line: hint, reminderId: reminder?.id))
            } else if let r = reminder, r.status.isDue {
                rows.append(PartRow(part: part, state: .due(reminderId: r.id), line: "Check due now", reminderId: r.id))
            } else if part == .battery, let b = batteryLine {
                rows.append(PartRow(part: part, state: .quiet, line: b, reminderId: reminder?.id))
            } else if let r = reminder, case .ok(let left?) = r.status {
                let what = part == .tyres ? "Pressure check" : "Check"
                rows.append(PartRow(part: part, state: .quiet, line: "\(what) in \(Int(left.rounded())) km", reminderId: r.id))
            } else if let left = ridesLeft[part], left > 0 {
                rows.append(PartRow(part: part, state: .learning(ridesLeft: left),
                                    line: "Learning \u{00B7} about \(left) more ride\(left == 1 ? "" : "s")", reminderId: reminder?.id))
            } else {
                rows.append(PartRow(part: part, state: .quiet, line: "Nothing found so far", reminderId: reminder?.id))
            }
        }
        // cards on top: red first, then amber issues, then due reminders; the rest keep their order
        let out = rows.filter(\.standsOut).sorted { rank($0) < rank($1) }
        return out + rows.filter { !$0.standsOut }
    }

    static func rank(_ r: PartRow) -> Int {
        switch r.state {
        case .issue(let red, _): return red ? 0 : 1
        default: return 2
        }
    }

    /// N10-19: the orange dot on the Scooter tab, only while a part has an open issue or is due
    public static func tabDot(_ rows: [PartRow]) -> Bool { rows.contains(where: \.standsOut) }

    /// N10-20: the Home line under the status pill, only when something is due: "<Part> · check in N km ›" (an issue first);
    /// nil when all is quiet (no "all OK")
    public static func homeLine(_ rows: [PartRow]) -> String? {
        guard let r = rows.first(where: \.standsOut) else { return nil }
        return "\(r.part.title) \u{00B7} \(r.line)"
    }
}

/// N10-13 "Log what I did": one tap; the km comes from the scooter; restarts the reminders and relearns the affected faults (A30)
public enum LogWhatIDid: String, CaseIterable, Codable, Sendable {
    case tyrePressure, replacedTyre, brakesAdjusted, replacedPads, boltsTightened, replacedBattery, replacedCharger, motorServiced,
         wiringRepaired

    public var title: String {
        switch self {
        case .tyrePressure: return "Checked tyre pressure"
        case .replacedTyre: return "Replaced a tyre"
        case .brakesAdjusted: return "Checked or adjusted brakes"
        case .replacedPads: return "Replaced brake pads"
        case .boltsTightened: return "Tightened bolts and folding joint"
        case .replacedBattery: return "Replaced the battery"
        case .replacedCharger: return "Replaced the charger"
        case .motorServiced: return "Motor serviced"
        case .wiringRepaired: return "Wiring or connectors repaired"
        }
    }

    public var part: MaintPart {
        switch self {
        case .tyrePressure, .replacedTyre: return .tyres
        case .brakesAdjusted, .replacedPads: return .brakes
        case .boltsTightened: return .bolts
        case .replacedBattery, .replacedCharger: return .battery
        case .motorServiced: return .motor
        case .wiringRepaired: return .electrics
        }
    }

    /// The km reminder this restarts
    public var reminderId: String? {
        switch part {
        case .tyres: return "tyres"
        case .brakes: return "brakes"
        case .bolts: return "bolts"
        default: return nil
        }
    }

    /// Whether the part's learned normal starts again (a check alone doesn't change the part)
    public var relearns: Bool { self != .tyrePressure && self != .brakesAdjusted && self != .boltsTightened }
}

/// N10-13 / N10-14: one entry the rider logged (date as a day number + km only)
public struct LoggedWork: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var what: LogWhatIDid
    public var scooterId: String
    public var day: Int
    public var odoKm: Double?

    public init(id: String = UUID().uuidString, what: LogWhatIDid, scooterId: String, day: Int, odoKm: Double?) {
        self.id = id
        self.what = what
        self.scooterId = scooterId
        self.day = day
        self.odoKm = odoKm
    }
}
