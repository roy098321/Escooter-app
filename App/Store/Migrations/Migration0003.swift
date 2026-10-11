import Foundation

/// Migration v3 (T-00 part 2, field kit): additive only. `prediction` = every estimate shown, with the actual outcome once its ride
/// is closed; `shadow_result` = what the other threshold values would have decided per ride. Existing rows are never touched.
enum Migration0003 {
    static let identifier = "v3"
    static let tables = ["prediction", "shadow_result"]

    static let sql = """
    CREATE TABLE prediction (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL, routeId TEXT, madeAt INTEGER NOT NULL,
      predicted REAL NOT NULL, aux REAL,
      rideId TEXT REFERENCES ride(id) ON DELETE CASCADE, actual REAL, settledAt INTEGER
    );
    CREATE INDEX prediction_made ON prediction(madeAt);
    CREATE TABLE shadow_result (
      rideId TEXT NOT NULL REFERENCES ride(id) ON DELETE CASCADE,
      rule TEXT NOT NULL, variant TEXT NOT NULL, decision TEXT NOT NULL,
      differs INTEGER NOT NULL DEFAULT 0, isStandard INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (rideId, rule, variant)
    );
    """
}
