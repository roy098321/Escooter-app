import Foundation

/// u46 (T-00 part 1): notes, thumbs and the last-15-minutes text on a temporary database.
enum FieldKitCheck {
    static func run() {
        var detail = "-"
        var ok = false
        do {
            let temp = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { temp.discardTemporary() }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try RideToolsSeed.ride(temp, id: "N1", startAt: now - 3_600_000)
            let store = FieldKitQueries(temp)
            try store.setNote(rideId: "N1", text: "Test note")
            try store.setNote(rideId: "N1", text: "Test note, edited")
            try store.setFeedback(kind: "end", subjectId: "N1", subjectText: nil, verdict: -1, reason: "Ended too early", note: "x")
            let notes = try store.rideNotesText()
            let thumbs = try store.feedbackText()
            ErrorLog.shared.add(level: "info", source: "developer", "u46 marker")
            let recent = RecentLogs.text()
            let a = notes.contains("Test note, edited") && !notes.contains("N1")
            let b = thumbs.contains("end · down · wrong: Ended too early")
            let c = recent.contains("u46 marker")
            ok = a && b && c
            detail = "ride-notes.txt \(a ? "ok" : "wrong") · feedback.txt \(b ? "ok" : "wrong") · last 15 minutes \(c ? "ok" : "wrong")"
        } catch {
            detail = error.localizedDescription
        }
        CheckResults.shared.set("u46", ok ? .pass : .fail, detail)
    }
}
