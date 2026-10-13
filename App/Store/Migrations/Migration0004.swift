import Foundation

/// Migration v4 (next field-test update): additive only. `price_history` = fuel price and electricity rate as value + "valid from" date
/// (F-01: a new price only applies from its date on, so past savings never change); `ride.usedPctShown` = the battery used a ride *shows*
/// (Battery per km fix: rested drop, else the next ride's rested start, else energy). Predictions keep reading `usedPct`, so none of them change.
/// Existing rows are never touched; the fuel prices already stored by month and a custom electricity rate are copied into the history.
enum Migration0004 {
    static let identifier = "v4"
    static let tables = ["price_history"]

    static let sql = """
    CREATE TABLE price_history (
      kind TEXT NOT NULL, validFrom TEXT NOT NULL, value REAL NOT NULL,
      source TEXT, unverified INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (kind, validFrom)
    );
    INSERT INTO price_history (kind, validFrom, value, source)
      SELECT 'fuel', month || '-01', priceIls, COALESCE(source, 'manual') FROM fuel_price
      WHERE priceIls IS NOT NULL AND priceIls > 0 AND length(month) = 7;
    INSERT OR IGNORE INTO price_history (kind, validFrom, value, source)
      SELECT 'electricity', '2000-01-01', CAST(json AS REAL), 'setting' FROM setting
      WHERE key = 'stats.electricityIlsPerKwh' AND CAST(json AS REAL) > 0;
    ALTER TABLE ride ADD COLUMN usedPctShown REAL;
    """
}
