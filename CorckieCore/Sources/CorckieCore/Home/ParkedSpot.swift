import Foundation

/// V17 (owner, 19 Oct): where the scooter was last parked. It comes from the end point already stored for the last ride (its last GPS
/// sample, else its end place), so nothing new is recorded. Shown as a pin on Home's map and a row on the Scooter tab
/// ("Parked · Work · 2 h ago", a tap opens a map). Pure helpers here; the database read is `ParkedLoader` in the app.
public struct ParkedSpot: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    /// when the last ride ended (epoch ms)
    public var endedAtMs: Int64
    /// the saved place the ride ended in, if any
    public var placeName: String?
    /// B34: the spot is where the phone was when the scooter last connected or disconnected, not a ride end ("Last seen here")
    public var isLastSeen = false
    /// B34: false when the scooter's odometer went up since this spot, so the scooter has moved and no pin is drawn
    public var confident = true

    public init(lat: Double, lon: Double, endedAtMs: Int64, placeName: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.endedAtMs = endedAtMs
        self.placeName = placeName
    }
}

public enum ParkedText {
    /// "just now", "12 min ago", "2 h ago", "yesterday", "3 days ago"
    public static func ago(endedAtMs: Int64, nowMs: Int64) -> String {
        let minutes = max(0, Int((nowMs - endedAtMs) / 60_000))
        switch minutes {
        case 0: return "just now"
        case 1..<60: return "\(minutes) min ago"
        case 60..<(24 * 60): return "\(minutes / 60) h ago"
        case (24 * 60)..<(48 * 60): return "yesterday"
        default: return "\(minutes / (24 * 60)) days ago"
        }
    }

    /// "Parked · Work · 2 h ago" (the place is left out when the ride did not end in a saved place)
    public static func line(_ spot: ParkedSpot, nowMs: Int64) -> String {
        // B34: "Last seen here · 2 h ago" (a connect / disconnect spot); "Last seen · 2 h ago" when the scooter has moved since
        if spot.isLastSeen || !spot.confident {
            let name = spot.placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let head = spot.confident ? "Last seen here" : "Last seen"
            return ([head] + (name.isEmpty ? [] : [name]) + [ago(endedAtMs: spot.endedAtMs, nowMs: nowMs)]).joined(separator: " \u{00B7} ")
        }
        let name = spot.placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (["Parked"] + (name.isEmpty ? [] : [name]) + [ago(endedAtMs: spot.endedAtMs, nowMs: nowMs)]).joined(separator: " \u{00B7} ")
    }
}

/// Where a coordinate falls on the Home map picture (a still `MKMapSnapshotter` image centred on the phone, `MapSnapshotStore`).
public enum ParkedPin {
    /// The picture covers `spanLatM` metres from top to bottom and `spanLonM` from left to right. Returns the point as a fraction of
    /// the picture (0...1 each way, y downwards), or nil when the spot is outside it.
    public static func fraction(lat: Double, lon: Double, centreLat: Double, centreLon: Double, spanLatM: Double, spanLonM: Double) -> (x: Double, y: Double)? {
        guard spanLatM > 0, spanLonM > 0 else { return nil }
        let northM = (lat - centreLat) * 111_320
        let eastM = (lon - centreLon) * 111_320 * cos(centreLat * .pi / 180)
        let x = 0.5 + eastM / spanLonM
        let y = 0.5 - northM / spanLatM
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x, y)
    }

    /// The picture is drawn "scaled to fill" a view: where a fraction of the picture lands in the view (points).
    public static func inFilledView(_ f: (x: Double, y: Double), imageAspect: Double, viewWidth: Double, viewHeight: Double) -> (x: Double, y: Double) {
        guard imageAspect > 0, viewWidth > 0, viewHeight > 0 else { return (0, 0) }
        // width / height of the picture is imageAspect; fill = the larger of the two scales
        let drawnHeight = max(viewHeight, viewWidth / imageAspect)
        let drawnWidth = drawnHeight * imageAspect
        return (viewWidth / 2 + (f.x - 0.5) * drawnWidth, viewHeight / 2 + (f.y - 0.5) * drawnHeight)
    }
}
