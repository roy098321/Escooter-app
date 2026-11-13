import CorckieCore
import Foundation

/// N5-1: applies `PrivacyExport` to the export tables (synthetic-data tested in AppTests). Works on `BundleTable` values already read from
/// the database; the database itself is never changed.
enum PrivacyTrim {
    /// Empties the names and free text of a table (all privacy levels except full).
    static func blank(_ table: BundleTable) -> BundleTable {
        guard let columns = PrivacyExport.blankedColumns[table.name] else { return table }
        var out = table
        let indexes = columns.compactMap { table.columns.firstIndex(of: $0) }
        for r in out.rows.indices { for i in indexes { out.rows[r][i] = .null } }
        return out
    }

    /// Saved-place centres from the (unblanked) place table.
    static func zonesFromPlaces(_ place: BundleTable) -> [(lat: Double, lon: Double)] {
        var zones: [(lat: Double, lon: Double)] = []
        for r in place.rows.indices {
            if case .double(let lat)? = place.value(r, "lat"), case .double(let lon)? = place.value(r, "lon") { zones.append((lat, lon)) }
        }
        return zones
    }

    /// One ride's samples: coordinates emptied inside a zone (the ride's first and last fix + `placeZones`), or everywhere for `noGPS`.
    static func trimSamples(_ samples: BundleTable, level: PrivacyLevel, placeZones: [(lat: Double, lon: Double)]) -> BundleTable {
        guard level != .full, let latI = samples.columns.firstIndex(of: "lat"), let lonI = samples.columns.firstIndex(of: "lon") else { return samples }
        let locationIdx = PrivacyExport.locationColumns.compactMap { samples.columns.firstIndex(of: $0) }
        func coordinate(_ row: [BundleValue]) -> (Double, Double)? {
            if case .double(let a) = row[latI], case .double(let b) = row[lonI] { return (a, b) }
            return nil
        }
        var zones = placeZones
        let fixes = samples.rows.compactMap(coordinate)
        if let first = fixes.first { zones.append((first.0, first.1)) }
        if let last = fixes.last { zones.append((last.0, last.1)) }
        var out = samples
        for r in out.rows.indices {
            let clear: Bool
            if level == .noGPS { clear = true } else if let c = coordinate(out.rows[r]) { clear = PrivacyExport.inZone(lat: c.0, lon: c.1, zones: zones) } else { clear = false }
            if clear { for i in locationIdx { out.rows[r][i] = .null } }
        }
        return out
    }
}
