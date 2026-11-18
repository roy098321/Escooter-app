import Foundation

/// A-17 (batch 9, owner 18 Nov, D-PR-12): every share or export of a ride (Ride Replay file, GPX, CSV) first asks
/// "Hide where this ride starts and ends?". Hide start and end (the main button) removes the location of every reading within
/// ~200 m of the ride's first and last GPS point, in the shared copy only; the ride in the app stays full. Speed, battery and the
/// rest stay, so the file still plays. Pure, tested on Linux.
public enum ShareTrim {
    public static let radiusM = PrivacyExport.trimRadiusM
    public static let question = "Hide where this ride starts and ends?"
    public static let hideButton = "Hide start and end"
    public static let fullButton = "Share full route"
    public static let message = "Cuts about 200 m at each end of the shared copy. The ride in the app stays full."

    /// The first and last points with a location
    public static func ends(_ rows: [ReplayRow]) -> [(lat: Double, lon: Double)] {
        let located = rows.compactMap { r -> (lat: Double, lon: Double)? in
            guard let lat = r.lat, let lon = r.lon else { return nil }
            return (lat, lon)
        }
        guard let first = located.first, let last = located.last else { return [] }
        return [first, last]
    }

    /// The rows with no location left within `radiusM` of the start or the end
    public static func hideEnds(_ rows: [ReplayRow]) -> [ReplayRow] {
        let zones = ends(rows)
        guard !zones.isEmpty else { return rows }
        return rows.map { r in
            guard let lat = r.lat, let lon = r.lon, PrivacyExport.inZone(lat: lat, lon: lon, zones: zones) else { return r }
            var out = r
            out.lat = nil
            out.lon = nil
            out.hAccM = nil
            out.altM = nil
            return out
        }
    }
}
