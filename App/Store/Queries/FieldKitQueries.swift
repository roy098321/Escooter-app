import Foundation
import GRDB

/// T-00 part 1: post-ride notes ("Note for Claude"), one-tap feedback and their export texts.
/// No CorckieCore import: App/Store is compiled into AppTests on its own.
struct FeedbackRecord: Equatable {
    var kind: String
    var subjectId: String
    var subjectText: String?
    /// 1 = thumbs up, -1 = thumbs down
    var verdict: Int
    var reason: String?
    var note: String?
    var at: Int64
}

struct FieldKitQueries {
    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    /// kinds: ride start / end / distance, insight, message
    static let rideKinds = ["start", "end", "distance"]

    /// The one "what was wrong" question per kind.
    static func reasons(for kind: String) -> [String] {
        switch kind {
        case "start": return ["Started too early", "Started too late", "Should not be a ride", "Other"]
        case "end": return ["Ended too early", "Ended too late", "Should have been two rides", "Other"]
        case "distance": return ["Too long", "Too short", "Other"]
        case "insight": return ["Not true", "Not useful", "Confusing wording", "Other"]
        default: return ["Should not have come", "Wrong time", "Not useful", "Other"]
        }
    }

    private func guardWritable() throws {
        if database.isReadOnly { throw RideQueries.StoreError.readOnly }
    }

    // MARK: Notes

    func note(rideId: String) throws -> String? {
        try database.writer.read { try String.fetchOne($0, sql: "SELECT note FROM ride_note WHERE rideId = ?", arguments: [rideId]) }
    }

    /// Empty text removes the note.
    func setNote(rideId: String, text: String, at: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        try guardWritable()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.writer.write { db in
            if clean.isEmpty {
                try db.execute(sql: "DELETE FROM ride_note WHERE rideId = ?", arguments: [rideId])
            } else {
                try db.execute(sql: """
                    INSERT INTO ride_note (rideId, note, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(rideId) DO UPDATE SET note = excluded.note, updatedAt = excluded.updatedAt
                    """, arguments: [rideId, clean, at])
            }
        }
    }

    // MARK: Feedback

    /// One answer per (kind, subject): answering again replaces it.
    func setFeedback(kind: String, subjectId: String, subjectText: String?, verdict: Int, reason: String? = nil,
                     note: String? = nil, at: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        try guardWritable()
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO feedback (kind, subjectId, subjectText, verdict, reason, note, at) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, subjectId) DO UPDATE SET subjectText = excluded.subjectText, verdict = excluded.verdict,
                  reason = excluded.reason, note = excluded.note, at = excluded.at
                """, arguments: [kind, subjectId, subjectText, verdict, reason, (cleanNote?.isEmpty ?? true) ? nil : cleanNote, at])
        }
    }

    func verdict(kind: String, subjectId: String) throws -> Int? {
        try database.writer.read {
            try Int.fetchOne($0, sql: "SELECT verdict FROM feedback WHERE kind = ? AND subjectId = ?", arguments: [kind, subjectId])
        }
    }

    func allFeedback() throws -> [FeedbackRecord] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM feedback ORDER BY at DESC").map { row in
                FeedbackRecord(kind: row["kind"], subjectId: row["subjectId"], subjectText: row["subjectText"],
                               verdict: row["verdict"], reason: row["reason"], note: row["note"], at: row["at"])
            }
        }
    }

    // MARK: Export texts

    /// ride-notes.txt: date, route name, distance, time, battery used, the note. No ride ids, no coordinates.
    func rideNotesText(now: Date = Date()) throws -> String {
        var out = "Ride notes (Note for Claude) · \(now.formatted())\n"
        let rows = try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ride.startAt, ride.distanceM, ride.totalS, ride.startRestPct, ride.endRestPct, ride.usedPct,
                       route.name AS routeName, ride.routeId, ride_note.note
                FROM ride_note JOIN ride ON ride.id = ride_note.rideId LEFT JOIN route ON route.id = ride.routeId
                ORDER BY ride.startAt DESC
                """)
        }
        out += "\(rows.count) notes (newest first)\n\n"
        for row in rows {
            let startAt: Int64 = row["startAt"]
            let date = Date(timeIntervalSince1970: Double(startAt) / 1000)
            let routeId: String? = row["routeId"]
            let routeName: String? = row["routeName"]
            var line = date.formatted(date: .abbreviated, time: .shortened)
            line += " · route: " + (routeName ?? (routeId == nil ? "none" : "unnamed"))
            if let d: Double = row["distanceM"] { line += " · " + String(format: "%.2f", d / 1000) + " km" }
            if let t: Double = row["totalS"] { line += " · \(Int(t / 60)) min" }
            let startPct: Double? = row["startRestPct"]
            let endPct: Double? = row["endRestPct"]
            let usedPct: Double? = row["usedPct"]
            if let a = startPct, let b = endPct {
                line += " · battery used \(Int(a - b))% (\(Int(a))→\(Int(b))%)"
            } else if let u = usedPct {
                line += " · battery used \(Int(u))%"
            }
            let note: String = row["note"]
            out += line + "\n  Note: " + note.replacingOccurrences(of: "\n", with: "\n  ") + "\n\n"
        }
        return out
    }

    /// feedback.txt: one line per answer.
    func feedbackText(now: Date = Date()) throws -> String {
        let rows = try allFeedback()
        var out = "Feedback (thumbs) · \(now.formatted())\n\(rows.count) answers (newest first)\n\n"
        for r in rows {
            let date = Date(timeIntervalSince1970: Double(r.at) / 1000)
            var line = date.formatted(date: .abbreviated, time: .shortened) + " · \(r.kind) · " + (r.verdict > 0 ? "up" : "down")
            if let text = r.subjectText, !text.isEmpty { line += " · \"\(text)\"" }
            if let reason = r.reason { line += " · wrong: \(reason)" }
            if let note = r.note { line += " · note: \(note)" }
            out += line + "\n"
        }
        return out
    }
}

extension FieldKitQueries {
    /// Messages the app really sent (newest first), so each can get a thumb.
    func recentSentMessages(limit: Int = 10) throws -> [(id: Int64, type: String, sentAt: Int64)] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, type, sentAt FROM message_log WHERE sentAt IS NOT NULL ORDER BY sentAt DESC LIMIT ?",
                             arguments: [limit]).map { row in
                (id: row["id"] as Int64, type: (row["type"] as String?) ?? "message", sentAt: row["sentAt"] as Int64)
            }
        }
    }
}
