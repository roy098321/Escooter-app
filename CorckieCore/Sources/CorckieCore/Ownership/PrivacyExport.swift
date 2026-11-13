import Foundation

/// N5-1: the export a tester can send. Nothing leaves the phone by itself; the rider shares the file.
/// Levels: `full` (the owner's own export, unchanged), `trimmed` (about 200 m around ride starts, ends and saved places removed, and no
/// names), `noGPS` (no coordinates at all). The pure rules are here; `PrivacyTrim` (App/Store/Bundle) applies them to the export tables.
public enum PrivacyLevel: String, CaseIterable, Sendable {
    case full, trimmed, noGPS

    public var title: String {
        switch self {
        case .full: return "Everything"
        case .trimmed: return "Privacy-safe"
        case .noGPS: return "No GPS at all"
        }
    }

    public var detail: String {
        switch self {
        case .full: return "Everything the app logs, including places and routes."
        case .trimmed: return "Removes about 200 m around where rides start and end and around your saved places. No place or route names."
        case .noGPS: return "No locations at all. No place or route names."
        }
    }
}

public enum PrivacyExport {
    /// Radius removed around ride starts, ends and saved places
    public static let trimRadiusM = 200.0

    /// Columns emptied in every table for `trimmed` and `noGPS`: names, free text, and locations of places, routes, stops and weather cells.
    public static let blankedColumns: [String: [String]] = [
        "place": ["name", "lat", "lon"],
        "route": ["name"],
        "variant": ["name", "polyline"],
        "choice_point": ["splitLat", "splitLon", "rejoinLat", "rejoinLon", "sideTag"],
        "choice_option": ["name", "polyline"],
        "climb": ["name"],
        "stop": ["lat", "lon"],
        "weather_hour": ["cellKey"],
        "elevation_point": ["cellKey"],
        "scooter": ["name", "peripheralId"],
        "ride_note": ["note"],
        "feedback": ["subjectText", "reason", "note"],
        "insight": ["text"]
    ]

    /// Sample columns that locate the rider; emptied inside a trimmed zone (or everywhere for `noGPS`). Speed, battery and the rest stay.
    public static let locationColumns = ["lat", "lon", "hAccM", "courseDeg", "altBaroM", "altFixedM"]

    /// Files that can hold locations or free text, left out of the trimmed and no-GPS exports.
    public static let omittedFolders = ["missed-ride-reports", "report"]

    /// Distance in metres between two points (haversine).
    public static func distanceM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// True when the point lies within the trim radius of any zone (ride start, ride end, saved place centres).
    public static func inZone(lat: Double, lon: Double, zones: [(lat: Double, lon: Double)]) -> Bool {
        zones.contains { distanceM(lat, lon, $0.lat, $0.lon) <= trimRadiusM }
    }
}
