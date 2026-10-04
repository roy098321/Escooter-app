import CorckieCore
import Foundation

/// u7 (M1-10): the "Going for a ride?" rules on a made-up night, with the real message_log table in a temporary
/// database and a recording stand-in for the notification centre (no real notification is sent).
enum NotifierCheck {
    private final class Recorder: NotificationSending, MessageLogging {
        var sent: [String] = []
        var removed = 0
        var entries: [MessageLogEntry] = []
        func send(id: String, title: String, body: String, soundName: String) {
            sent.append(title + " | " + body + " | " + soundName)
        }
        func remove(id: String) { removed += 1 }
        func log(_ entry: MessageLogEntry) { entries.append(entry) }
    }

    static func run() {
        var notes: [String] = []
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            notes.append((condition ? "✓ " : "✗ ") + what)
            if !condition { ok = false }
        }

        let rec = Recorder()
        let n = GoingForARideNotifier(sender: rec, logger: rec)
        let night = 23.5 * 3600                      // 23:30, inside quiet hours
        n.scooterConnected(at: night, appActive: false, rideActive: false)
        n.batteryReading(pct: 91, at: night + 1, appActive: false, rideActive: false)
        expect(rec.sent == ["Scooter on · 91% | Going for a ride? Tap here | chime2_kickoff.wav"], "sent at 23:30 with battery and Kick-off chime")
        for t in [30.0, 90.0, 150.0] {
            n.scooterDisconnected(at: night + t)
            n.scooterConnected(at: night + t + 20, appActive: false, rideActive: false)
            n.batteryReading(pct: 91, at: night + t + 21, appActive: false, rideActive: false)
        }
        expect(rec.sent.count == 1, "3 reconnect blips: still one")
        n.rideStarted(at: night + 200)
        expect(rec.removed == 1, "removed when the ride starts")

        n.powerOff(at: night + 900)
        n.scooterConnected(at: night + 1000, appActive: true, rideActive: false)
        expect(rec.sent.count == 1 && rec.entries.last?.droppedReason == "app on screen", "never with the app open")
        n.powerOff(at: night + 1100)
        n.scooterConnected(at: night + 1200, appActive: false, rideActive: true)
        expect(rec.sent.count == 1 && rec.entries.last?.droppedReason == "ride in progress", "never during a ride")
        n.powerOff(at: night + 1300)
        n.scooterConnected(at: night + 1400, appActive: false, rideActive: false)
        n.batteryReading(pct: 88, at: night + 1401, appActive: false, rideActive: false)
        n.scooterDisconnected(at: night + 1500)
        n.tick(at: night + 1500 + 121, appActive: false, rideActive: false)
        expect(rec.sent.count == 2 && rec.removed == 2, "new power-on sends again; removed after a 2+ min disconnect (auto-off)")

        // the message_log table (temporary database)
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let store = MessageLogQueries(temp)
            for e in rec.entries {
                try store.add(type: e.type, channel: e.channel, at: Int64(e.at * 1000), droppedReason: e.droppedReason)
            }
            let rows = try store.entries(type: GoingForARideRule.messageType)
            expect(rows.count == rec.entries.count && rows.filter { $0.droppedReason != nil }.count == 2,
                   "\(rows.count) message_log rows (2 sent, 2 dropped with a reason)")
        } catch {
            expect(false, "message log failed: \(error.localizedDescription)")
        }

        CheckResults.shared.set("u7", ok ? .pass : .fail, notes.joined(separator: " · "))
    }
}
