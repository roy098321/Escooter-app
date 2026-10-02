import CorckieCore
import Foundation

/// Developer raw-data recorder (ARCHITECTURE §2.2 #16): the last 60,000 scooter packets with
/// their arrival time, step label and app state. Exported in the P2 Lab CSV format
/// (`time,step,app_state,bytes`), so an export can go straight through Tools/anonymise.py
/// and become a new fixture.
final class PacketLog {
    static let shared = PacketLog()

    struct Row {
        let time: Date
        let step: String
        let background: Bool
        let bytes: [UInt8]
    }

    private(set) var rows: [Row] = []
    /// The label of a recording step (e.g. "t7-lock"), nil = live
    var step: String?

    func add(_ bytes: [UInt8], at time: Date, background: Bool) {
        rows.append(Row(time: time, step: step ?? (background ? "background" : "live"), background: background, bytes: bytes))
        if rows.count > 60_000 { rows.removeFirst(10_000) }
    }

    func rows(forStep id: String) -> [Row] {
        rows.filter { $0.step == id }
    }

    func csv() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "time,step,app_state,bytes\n"
        out.reserveCapacity(rows.count * 90)
        for row in rows {
            out += "\(formatter.string(from: row.time)),\(row.step),\(row.background ? "background" : "open"),\(Hex.string(row.bytes))\n"
        }
        return out
    }
}
