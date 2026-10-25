import Foundation

/// F-35 (owner 22 Oct, note 4): the destination on the live ride screen.
/// (a) Once, a few seconds after a ride with a destination starts, the voice says "Riding to Uni, 8 km." (nothing without a destination).
/// (b) Tapping the destination line WHEN STOPPED opens the quick-dial icons (+ ? no destination); a new pick says "Riding to B, 3 km." at once,
///     and the arrival time and the F-22 battery check switch to it. While moving the tap only shows "Stop to change".
/// (c) The ride is always saved with where it actually ended (the end place comes from the ride's own end, not from this choice).
/// B62 leftover: a ride without a destination (one that started by itself in the background) shows "Where to?" on the live screen.
/// Rejected: switching the destination by guessing.
public enum DestinationLive {
    /// seconds of riding before the start line is spoken
    public static let announceAfterS = 5.0
    /// at or below this the scooter counts as stopped (the destination can be changed)
    public static let stoppedKmh = 2
    public static let stopToChange = "Stop to change"
    public static let whereTo = "Where to?"

    /// "8 km", "1.5 km", "0.4 km" (whole km from 10 km up, else one decimal)
    public static func kmText(_ m: Double) -> String {
        let km = max(0, m) / 1000
        if km >= 10 { return "\(Int(km.rounded())) km" }
        let tenth = (km * 10).rounded() / 10
        if tenth == tenth.rounded() { return "\(Int(tenth)) km" }
        return String(format: "%.1f km", tenth)
    }

    /// "Riding to Uni, 8 km." or "Riding to Uni." when the distance is unknown
    public static func ridingLine(name: String, distanceM: Double?) -> String {
        guard let d = distanceM, d >= 0 else { return "Riding to \(name)." }
        return "Riding to \(name), \(kmText(d))."
    }

    /// The tap on the destination line: unknown speed counts as moving (never open the picker while it may be moving)
    public static func canChange(speedKmh: Int?) -> Bool {
        guard let v = speedKmh else { return false }
        return v <= stoppedKmh
    }

    /// The distance said with the line: what is left along a followed route, else the straight line to the destination's point
    public static func distanceM(progress: RouteLiveProgress?, position: GeoPoint?, end: GeoPoint?) -> Double? {
        if let p = progress { return max(0, p.routeKm - p.alongKm) * 1000 }
        guard let position, let end else { return nil }
        return Geo.distanceM(position, end)
    }
}

/// F-35: decides when "Riding to …" is spoken. Once per ride, `announceAfterS` after riding began, when a destination is set; again at once
/// (on the next update) when the rider picks another destination during the ride. Clearing the destination says nothing.
public struct DestinationAnnouncer: Equatable, Sendable {
    private var ridingSince: Double?
    private var spokenKey: String?
    private var startDone = false

    public init() {}

    public mutating func reset() { self = DestinationAnnouncer() }

    /// - riding: the ride is in the riding phase; key: the destination now (nil = none)
    /// - Returns: true when the line for `key` is to be spoken now
    public mutating func update(riding: Bool, key: String?, at t: Double) -> Bool {
        guard riding else {
            if ridingSince != nil { reset() }
            return false
        }
        if ridingSince == nil { ridingSince = t }
        if !startDone {
            guard t - (ridingSince ?? t) >= DestinationLive.announceAfterS else { return false }
            startDone = true
            spokenKey = key
            return key != nil
        }
        guard key != spokenKey else { return false }
        spokenKey = key
        return key != nil
    }
}
