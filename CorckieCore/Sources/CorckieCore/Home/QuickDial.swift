import Foundation

/// F-29 (owner, 20 Oct): the icon of a place. Either one of 16 SF Symbols or one or two typed letters, drawn in the same round style. No emoji.
/// Stored per place as the setting `place.icon.<id>` (a JSON string, no schema change) in the form "sf:house" or "tx:MA".
public enum PlaceIcon: Equatable, Sendable {
    case symbol(String)
    case letters(String)

    /// The 4 x 4 grid, row by row: house, work, school, gym / shop, cafe, food, heart / people, clinic, family, park /
    /// beach, charging spot, culture, train. All exist in SF Symbols 5 (iOS 17); the app has a check that each one resolves.
    public static let symbols: [String] = [
        "house", "building.2", "graduationcap", "dumbbell",
        "cart", "cup.and.saucer", "fork.knife", "heart",
        "person.2", "cross.case", "figure.and.child.holdinghands", "tree",
        "beach.umbrella", "bolt", "building.columns", "tram"
    ]
    /// shown when a stored symbol name is unknown
    public static let fallbackSymbol = "mappin"

    public static func settingKey(_ placeId: String) -> String { "place.icon.\(placeId)" }

    public var code: String {
        switch self {
        case .symbol(let s): return "sf:\(s)"
        case .letters(let t): return "tx:\(t)"
        }
    }

    public static func parse(_ code: String?) -> PlaceIcon? {
        guard let code else { return nil }
        if code.hasPrefix("sf:") {
            let name = String(code.dropFirst(3))
            return symbols.contains(name) ? .symbol(name) : nil
        }
        if code.hasPrefix("tx:") {
            let t = clean(String(code.dropFirst(3)))
            return t.isEmpty ? nil : .letters(t)
        }
        return nil
    }

    /// 1 or 2 letters or digits, upper case; anything else (spaces, symbols, emoji) is dropped
    public static func clean(_ typed: String) -> String {
        var out = ""
        for scalar in typed.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) && scalar.value < 0x2000 {
            if out.unicodeScalars.count >= 2 { break }
            out.unicodeScalars.append(scalar)
        }
        return out.uppercased()
    }

    /// The icon a place shows when none was picked: the first letter of its name ("Maya's house" gives "M"), "?" without a name
    public static func automatic(name: String?) -> PlaceIcon {
        let first = clean(String((name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
        return .letters(first.isEmpty ? "?" : first)
    }
}

/// A place as the quick dial ranks it
public struct QuickDialPlace: Equatable, Sendable {
    public var id: String
    public var name: String?
    /// rides that ended here
    public var visits: Int
    /// 1, 2, 3 ... when the owner pinned it with "Show on Home" (the order they chose), else nil
    public var pinOrder: Int?

    public init(id: String, name: String?, visits: Int, pinOrder: Int? = nil) {
        self.id = id
        self.name = name
        self.visits = visits
        self.pinOrder = pinOrder
    }
}

public enum QuickDial {
    /// Slots on Home: 3, and 2 at the largest Dynamic Type sizes
    public static func slotCount(accessibilitySize: Bool) -> Int { accessibilitySize ? 2 : 3 }

    public static func homeKey(_ placeId: String) -> String { "place.home.\(placeId)" }

    /// The places on the quick dial: pinned ones first in the owner's order, then the most visited ride end places. Only places
    /// with a name count (a nameless place has nothing to say on a button). A tie goes to the older id so the order never flickers.
    public static func slots(_ places: [QuickDialPlace], count: Int) -> [String] {
        let named = places.filter { !($0.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pinned = named.filter { $0.pinOrder != nil }.sorted { ($0.pinOrder ?? 0, $0.id) < ($1.pinOrder ?? 0, $1.id) }
        let rest = named.filter { $0.pinOrder == nil && $0.visits > 0 }.sorted { ($1.visits, $0.id) < ($0.visits, $1.id) }
        return Array((pinned + rest).map(\.id).prefix(max(0, count)))
    }

    /// The line under the icons: always what was chosen. "Maya's house · 12 min · needs ~9 %" or "No destination".
    public static func summary(name: String?, minutes: Int?, needPct: Double?) -> String {
        guard let name, !name.isEmpty else { return "No destination" }
        var parts = [name]
        if let minutes { parts.append("\(minutes) min") }
        if let needPct { parts.append("needs ~\(Int(needPct.rounded())) %") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// B31 (owner, 20 Oct): a saved place is a destination even when no saved route ends there. Then the time and the battery need come from the
/// straight line at the rider's usual speed and usual battery use per km. These numbers are shown as they are (honest); the +10 % safety margin
/// (policy P-1) is applied where the app acts on them (`DestinationRules.preRideWarning`).
public enum PlaceDestination {
    /// used when the rider has no rides to take a usual speed from
    public static let fallbackMps = 5.5

    public struct Estimate: Equatable, Sendable {
        public var distanceM: Double
        public var timeS: Double
        /// nil without a usual battery use per km
        public var usedPct: Double?
        public var minutes: Int { max(1, Int((timeS / 60).rounded())) }
    }

    /// nil when the distance is unknown or the speed is not above zero
    public static func estimate(distanceM: Double?, usualMps: Double?, usualPctPerKm: Double?) -> Estimate? {
        guard let d = distanceM, d >= 0 else { return nil }
        let v = (usualMps ?? 0) > 0 ? usualMps ?? fallbackMps : fallbackMps
        let used = usualPctPerKm.flatMap { $0 > 0 ? d / 1000 * $0 : nil }
        return Estimate(distanceM: d, timeS: d / v, usedPct: used)
    }

    /// Median of the rider's moving speeds (m/s) over all rides; nil without rides
    public static func usualMps(_ rides: [RouteRideStats]) -> Double? {
        Geo.median(rides.filter { !$0.excluded }.compactMap { r -> Double? in
            guard let v = r.avgMovingMps, v > 0.5 else { return nil }
            return v
        })
    }
}

/// B35 (owner, 20 Oct): the scooter's odometer on connect is higher than at the end of the last recorded ride, so some riding was not
/// recorded. Shown on Home and as a placeholder in Rides.
public enum OdometerGap {
    /// the odometer has 0.1 km steps and a ride end can be detected a little late; below this it is not a gap
    public static let minKm = 0.3

    /// - connectKm: the odometer now; lastRideEndKm: the odometer at the end of the newest finished ride (nil = unknown, no verdict);
    ///   lastGapToKm: the odometer up to which an earlier gap was already noted
    public static func km(connectKm: Double?, lastRideEndKm: Double?, lastGapToKm: Double?) -> Double? {
        guard let now = connectKm, let end = lastRideEndKm else { return nil }
        let from = max(end, lastGapToKm ?? 0)
        let gap = now - from
        return gap > minKm ? gap : nil
    }

    public static func kmText(_ km: Double) -> String { String(format: "%.1f km", km) }
    public static func homeLine(km: Double) -> String { "\(kmText(km)) ridden without recording" }
    public static func rideRow(km: Double) -> String { "Not recorded \u{00B7} \(kmText(km))" }
}

/// B34 (owner, 20 Oct): where the phone was when the scooter connected or disconnected. The phone's location counts only when it is good
/// enough (a fix of at most ~50 m accuracy that is at most 2 minutes old).
public struct LastSeenSpot: Codable, Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var atMs: Int64
    /// the scooter's odometer when it was saved (nil until the first packet of the connection arrives)
    public var odoKm: Double?

    public init(lat: Double, lon: Double, atMs: Int64, odoKm: Double? = nil) {
        self.lat = lat
        self.lon = lon
        self.atMs = atMs
        self.odoKm = odoKm
    }

    public static let maxAccuracyM = 50.0
    public static let maxAgeS = 120.0

    public static func fixUsable(accuracyM: Double, ageS: Double) -> Bool {
        accuracyM >= 0 && accuracyM <= maxAccuracyM && ageS >= 0 && ageS <= maxAgeS
    }
}

/// B34: the parked spot is the newest of the last ride's end and the last-seen spot.
public enum ParkedChoice {
    /// - rideEndOdoKm: the odometer at the end of that ride; currentOdoKm: the odometer now (nil = not connected / unknown)
    /// If the odometer went up since the newest spot (beyond `OdometerGap.minKm`) the scooter has moved, so the spot is kept but marked
    /// not confident (no pin on the map).
    public static func choose(ride: ParkedSpot?, seen: LastSeenSpot?, rideEndOdoKm: Double?, currentOdoKm: Double?) -> ParkedSpot? {
        func advanced(since odo: Double?) -> Bool {
            guard let odo, let now = currentOdoKm else { return false }
            return now - odo > OdometerGap.minKm
        }
        if let seen, seen.atMs > (ride?.endedAtMs ?? Int64.min) {
            var spot = ParkedSpot(lat: seen.lat, lon: seen.lon, endedAtMs: seen.atMs, placeName: nil)
            spot.isLastSeen = true
            spot.confident = !advanced(since: seen.odoKm)
            return spot
        }
        guard var spot = ride else { return nil }
        spot.confident = !advanced(since: rideEndOdoKm)
        return spot
    }
}
