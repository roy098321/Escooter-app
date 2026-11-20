import Foundation

// N10-14 (batch 10, owner 20 Nov: un-parked, the FULL service book; mock history2.png): for the rider to keep track and to show a
// buyer. Summary (scooter, km, tracked since, battery health), counts (logged · found · dealt with · open), a timeline by year with
// "Measured" (the app saw it in the scooter's data) and "Entered" (the owner logged it) marks; fault rows show their outcome.
// Dates as day numbers and km only: never a time of day, never a place or route.

public struct HistoryEntry: Equatable, Identifiable, Sendable {
    public enum Source: String, Sendable { case measured = "Measured", entered = "Entered" }
    public enum Outcome: String, Sendable { case open = "Open", checkedFine = "Checked fine", fixed = "Fixed" }

    public var id: String
    public var title: String
    public var part: MaintPart?
    public var day: Int
    public var odoKm: Double?
    public var source: Source
    /// Fault rows only
    public var outcome: Outcome?
    /// A fault (shown with "!")
    public var isFault: Bool
}

public struct HistoryCounts: Equatable, Sendable {
    public var logged: Int
    public var found: Int
    public var dealtWith: Int
    public var open: Int
}

public enum MaintHistory {
    /// The fault's history title ("Tyre soft or worn", "Power cut while riding")
    public static func title(_ k: FaultKind) -> String {
        switch k {
        case .f1Sag: return "Battery strained under load"
        case .f2PowerCut: return "Power cut while riding"
        case .f3BrakeCut: return "Brakes not cutting the motor"
        case .f5Tyre: return "Tyre soft or worn"
        case .f6Heat: return "Motor ran hot"
        case .f7Sensor: return "Sensor readings that can't be right"
        case .f11ParkedDrain: return "Battery drained while parked"
        case .f12FullVoltage: return "Charger not filling the battery"
        case .f16OdoReset: return "Km counter reset"
        }
    }

    /// Newest first. `trackedSince` = the first ride the app recorded (day + km): the "Tracking started" row.
    public static func entries(logged: [LoggedWork], faults: [FaultRecord], scooterId: String,
                               trackedSince: (day: Int, odoKm: Double?)?) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for w in logged where w.scooterId == scooterId {
            out.append(HistoryEntry(id: w.id, title: w.what.title, part: w.what.part, day: w.day, odoKm: w.odoKm, source: .entered,
                                    outcome: nil, isFault: false))
        }
        for f in faults where f.scooterId == scooterId {
            let o: HistoryEntry.Outcome = f.status == .fixed ? .fixed : f.status == .checkedFine ? .checkedFine : .open
            out.append(HistoryEntry(id: f.id, title: title(f.kind), part: f.kind.part, day: f.day, odoKm: f.odoKm, source: .measured,
                                    outcome: f.kind == .f16OdoReset ? nil : o, isFault: f.kind != .f16OdoReset))
        }
        if let t = trackedSince {
            out.append(HistoryEntry(id: "tracking-started", title: "Tracking started", part: nil, day: t.day, odoKm: t.odoKm,
                                    source: .measured, outcome: nil, isFault: false))
        }
        return out.sorted { $0.day != $1.day ? $0.day > $1.day : ($0.odoKm ?? 0) > ($1.odoKm ?? 0) }
    }

    public static func counts(_ entries: [HistoryEntry]) -> HistoryCounts {
        let faults = entries.filter(\.isFault)
        return HistoryCounts(logged: entries.filter { $0.source == .entered }.count,
                             found: faults.count,
                             dealtWith: faults.filter { $0.outcome == .fixed || $0.outcome == .checkedFine }.count,
                             open: faults.filter { $0.outcome == .open }.count)
    }

    /// Group by year (newest year first); `year` turns a day number into the rider's calendar year
    public static func byYear(_ entries: [HistoryEntry], year: (Int) -> Int) -> [(year: Int, entries: [HistoryEntry])] {
        var groups: [Int: [HistoryEntry]] = [:]
        for e in entries { groups[year(e.day), default: []].append(e) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }
}
