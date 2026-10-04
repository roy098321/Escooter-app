import CorckieCore
import Foundation
import UIKit

/// Developer raw-data recorder (ARCHITECTURE §2.2 #16): the last 60,000 scooter packets of
/// this session in memory, and (B03) the last 2,000 kept on disk so an export made after a
/// relaunch still has them. Exported in the P2 Lab CSV format (`time,step,app_state,bytes`),
/// so an export can go straight through Tools/anonymise.py and become a new fixture.
final class PacketLog {
    static let shared = PacketLog()
    static let keptOnDisk = 2_000

    struct Row {
        let time: Date
        let step: String
        let background: Bool
        let bytes: [UInt8]
    }

    private(set) var rows: [Row] = []
    /// The label of a recording step (e.g. "b5"), nil = live
    var step: String?

    private var sinceSave = 0
    private let file: URL? = try? FileManager.default
        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("last-scooter-packets.csv")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.save() }
    }

    func add(_ bytes: [UInt8], at time: Date, background: Bool) {
        rows.append(Row(time: time, step: step ?? (background ? "background" : "live"), background: background, bytes: bytes))
        if rows.count > 60_000 { rows.removeFirst(10_000) }
        sinceSave += 1
        if sinceSave >= 500 { save() }
    }

    func rows(forStep id: String) -> [Row] {
        rows.filter { $0.step == id }
    }

    /// This session's packets; after a relaunch with none yet, the last 2,000 saved ones.
    func csv() -> String {
        if rows.isEmpty, let file, let saved = try? String(contentsOf: file, encoding: .utf8) {
            return saved
        }
        return text(of: rows[...])
    }

    private func save() {
        sinceSave = 0
        guard let file, !rows.isEmpty else { return }
        let tail = rows.suffix(Self.keptOnDisk)
        try? text(of: tail).write(to: file, atomically: true, encoding: .utf8)
    }

    private func text(of slice: ArraySlice<Row>) -> String {
        var out = "time,step,app_state,bytes\n"
        out.reserveCapacity(slice.count * 90)
        for row in slice {
            out += "\(formatter.string(from: row.time)),\(row.step),\(row.background ? "background" : "open"),\(Hex.string(row.bytes))\n"
        }
        return out
    }
}
