import CorckieCore
import Foundation

/// B102 (.05): the quiet watch log for undecoded G500 bytes (`ByteWatch`). Silent: no UI, no notification. Kept on the
/// phone (newest 500, 60 days) and written into Export everything (`ExportDevLogs`), nowhere else.
final class ByteWatchStore {
    static let shared = ByteWatchStore()
    private static let key = "corckie.byteWatch"

    private var watch = ByteWatch()
    private var entries: [ByteWatchEntry]
    private let defaults = UserDefaults.standard

    private init() {
        entries = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([ByteWatchEntry].self, from: $0) } ?? []
    }

    var all: [ByteWatchEntry] { entries }

    func connected() { watch.connected(id: UUID().uuidString.prefix(8).lowercased()) }

    func packet(_ bytes: [UInt8], at date: Date) {
        let now = Int64(date.timeIntervalSince1970 * 1000)
        let new = watch.observe(bytes, atMs: now)
        guard !new.isEmpty else { return }
        entries = ByteWatch.trimmed(entries + new, nowMs: now)
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

/// B102 (.05): developer logs inside Export everything (Restore ignores them: nothing is brought back)
struct ExportDevLogs: Codable {
    var byteWatch: [ByteWatchEntry]
    var bluetoothEvents: [String]

    static func current() -> ExportDevLogs {
        ExportDevLogs(byteWatch: ByteWatchStore.shared.all, bluetoothEvents: AppModel.shared.scooter.events)
    }
}
