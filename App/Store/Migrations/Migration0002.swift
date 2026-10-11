import Foundation

/// Migration v2 (T-00 part 1, field kit): additive only. `ride_note` = the owner's "Note for Claude" per ride,
/// `feedback` = one-tap thumbs answers (+ "what was wrong"). Existing rows are never touched.
enum Migration0002 {
    static let identifier = "v2"
    static let tables = ["ride_note", "feedback"]

    static let sql = """
    CREATE TABLE ride_note (
      rideId TEXT PRIMARY KEY NOT NULL REFERENCES ride(id) ON DELETE CASCADE,
      note TEXT NOT NULL, updatedAt INTEGER NOT NULL
    );
    CREATE TABLE feedback (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL, subjectId TEXT NOT NULL, subjectText TEXT,
      verdict INTEGER NOT NULL, reason TEXT, note TEXT, at INTEGER NOT NULL,
      UNIQUE(kind, subjectId)
    );
    """
}
