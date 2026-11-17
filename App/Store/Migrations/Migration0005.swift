import Foundation

/// Migration v5 (batch 6): additive only. N6-1 (B95): `place.removedAt` = when the rider removed the place (ms, nil = in use). A removed
/// place is never dropped: past rides, routes and stats keep its name, it only leaves Where to, quick dial, Places, map pins and the
/// matching of new rides. "Put back" clears the stamp.
enum Migration0005 {
    static let identifier = "v5"

    static let sql = """
    ALTER TABLE place ADD COLUMN removedAt INTEGER;
    """
}
