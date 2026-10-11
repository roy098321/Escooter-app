import Foundation

/// a9 (T-02): the update check. Row counts per table are taken before the migrations of the first launch after an update and again after
/// them. It passes when no table lost rows; a table that is new in this build is allowed (it only has to exist).
public enum UpdateCheckRules {
    public struct Verdict: Equatable {
        public let passed: Bool
        /// "ride 3 -> 2" for every table that lost rows or vanished
        public let lost: [String]
        public let newTables: [String]
        public let tablesBefore: Int
        public let rowsBefore: Int
        public let rowsAfter: Int

        public var note: String {
            if passed {
                let added = newTables.isEmpty ? "" : " · new: " + newTables.joined(separator: ", ")
                return "No table lost rows: \(tablesBefore) tables, \(rowsBefore) rows before, \(rowsAfter) after\(added)"
            }
            return "Rows lost: " + lost.joined(separator: ", ")
        }
    }

    public static func verdict(before: [String: Int], after: [String: Int]) -> Verdict {
        var lost: [String] = []
        for table in before.keys.sorted() {
            guard let now = after[table] else { lost.append("\(table) \(before[table] ?? 0) -> table missing"); continue }
            if now < (before[table] ?? 0) { lost.append("\(table) \(before[table] ?? 0) -> \(now)") }
        }
        let added = after.keys.filter { before[$0] == nil }.sorted()
        return Verdict(passed: lost.isEmpty, lost: lost, newTables: added, tablesBefore: before.count,
                       rowsBefore: before.values.reduce(0, +), rowsAfter: after.values.reduce(0, +))
    }
}
