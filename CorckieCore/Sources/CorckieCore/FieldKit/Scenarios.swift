import Foundation

// T-00 part 2 (P6_PLAN section 2, point 7 and 2b): the scenario list in Checks (group "P6 scenarios"). Each scenario ticks
// itself when a real ride shows it. Pure rules over a few facts per ride; `App/Diagnostics/ScenarioChecks.swift` reads the facts.

public struct ScenarioRide: Equatable, Sendable {
    public var id: String
    public var startAtMs: Int64
    public var endAtMs: Int64
    public var utcOffsetMin: Int
    public var totalS: Double
    public var distanceM: Double
    /// Rested battery % at the start, else the first live %
    public var startPct: Double?
    /// `ride.wet`: "dry" or a wet level, nil = weather not here yet
    public var wet: String?
    public var gapGpsS: Double
    public var hasGps: Bool
    public var loadKg: Double?
    public var loadLevel: String?
    /// No earlier ride on the same route (or on no route at all)
    public var firstOnItsRoute: Bool
    /// `ride.endReason`: "standstill" = the scooter stayed on and connected for 10 minutes without moving (left on)
    public var endReason: String?

    public init(id: String, startAtMs: Int64, endAtMs: Int64, utcOffsetMin: Int = 0, totalS: Double = 0, distanceM: Double = 0,
                startPct: Double? = nil, wet: String? = nil, gapGpsS: Double = 0, hasGps: Bool = true, loadKg: Double? = nil,
                loadLevel: String? = nil, firstOnItsRoute: Bool = false, endReason: String? = nil) {
        self.endReason = endReason
        self.id = id
        self.startAtMs = startAtMs
        self.endAtMs = endAtMs
        self.utcOffsetMin = utcOffsetMin
        self.totalS = totalS
        self.distanceM = distanceM
        self.startPct = startPct
        self.wet = wet
        self.gapGpsS = gapGpsS
        self.hasGps = hasGps
        self.loadKg = loadKg
        self.loadLevel = loadLevel
        self.firstOnItsRoute = firstOnItsRoute
    }
}

/// Moments the app noted while a ride was on (epoch ms), plus the charges found between rides.
public struct ScenarioMarks: Equatable, Sendable {
    /// The phone was in Low Power Mode
    public var lowPowerAt: [Int64]
    /// The CorckieApp screen was on (app active) during a ride
    public var screenOnAt: [Int64]
    /// When the screen-state tracking began (rides before it cannot be called "screen off")
    public var screenTrackingSince: Int64?
    /// Rides that have a charge found after them
    public var chargedAfterRideIds: Set<String>

    public init(lowPowerAt: [Int64] = [], screenOnAt: [Int64] = [], screenTrackingSince: Int64? = nil,
                chargedAfterRideIds: Set<String> = []) {
        self.lowPowerAt = lowPowerAt
        self.screenOnAt = screenOnAt
        self.screenTrackingSince = screenTrackingSince
        self.chargedAfterRideIds = chargedAfterRideIds
    }
}

public enum ScenarioRules {
    /// Check IDs of the P6 group (in list order)
    public static let ids = ["p6lb", "p6rain", "p6night", "p6gps", "p6load", "p6route", "p6lpm", "p6left", "p6chg", "p6pocket"]

    /// A ride this long with the screen off all the way counts as a pocket ride
    public static let pocketMinS = 300.0
    public static let gpsLossS = 20.0
    /// Night = from 20:00 to 06:00 local
    public static let nightFromHour = 20
    public static let nightToHour = 6

    /// Passing verdicts only: a scenario that has not happened has no verdict (it stays on the To do list).
    /// `rides` are real, ended, non-short rides.
    public static func evaluate(_ rides: [ScenarioRide], marks: ScenarioMarks) -> [RideCheckVerdict] {
        var out: [RideCheckVerdict] = []
        func pass(_ id: String, _ matched: [ScenarioRide], _ what: String) {
            guard let newest = matched.max(by: { $0.startAtMs < $1.startAtMs }) else { return }
            out.append(RideCheckVerdict(id: id, result: .pass, note: "\(what) \u{00B7} \(matched.count) \(matched.count == 1 ? "ride" : "rides"), newest \(dayText(newest))"))
        }
        pass("p6lb", rides.filter { ($0.startPct ?? 100) < T.t81LowBatteryPct }, "Ride started below \(Int(T.t81LowBatteryPct))% battery")
        pass("p6rain", rides.filter { $0.wet != nil && $0.wet != "dry" }, "Ride in rain")
        pass("p6night", rides.filter { isNight($0.startAtMs, $0.utcOffsetMin) || isNight($0.endAtMs, $0.utcOffsetMin) }, "Ride at night")
        pass("p6gps", rides.filter { $0.hasGps && $0.gapGpsS >= gpsLossS }, "Ride with GPS lost for \(Int(gpsLossS)) s or more")
        pass("p6load", rides.filter { ($0.loadKg ?? 0) >= T.t75HeavyLoadKg || $0.loadLevel == "heavy" }, "Ride with a heavy load")
        pass("p6route", rides.filter { $0.firstOnItsRoute && $0.hasGps && $0.distanceM >= 1_000 }, "Ride on a new route")
        pass("p6lpm", rides.filter { within($0, marks.lowPowerAt) }, "Ride with the phone in Low Power Mode")
        pass("p6chg", rides.filter { marks.chargedAfterRideIds.contains($0.id) }, "Charge found after a ride")
        if let since = marks.screenTrackingSince {
            pass("p6pocket", rides.filter { $0.startAtMs >= since && $0.totalS >= pocketMinS && !within($0, marks.screenOnAt) },
                 "Ride with the screen off the whole way")
        }
        pass("p6left", rides.filter { $0.endReason == "standstill" }, "Scooter left on until the ride ended by itself")
        return out
    }

    static func within(_ r: ScenarioRide, _ marks: [Int64]) -> Bool {
        marks.contains { $0 >= r.startAtMs - 60_000 && $0 <= r.endAtMs + 60_000 }
    }

    static func localHour(_ ms: Int64, _ offsetMin: Int) -> Int {
        let local = ms / 1000 + Int64(offsetMin) * 60
        return Int((((local % 86_400) + 86_400) % 86_400) / 3_600)
    }

    static func isNight(_ ms: Int64, _ offsetMin: Int) -> Bool {
        let h = localHour(ms, offsetMin)
        return h >= nightFromHour || h < nightToHour
    }

    /// "11 Oct" style day text without the year, from the ride's own offset
    static func dayText(_ r: ScenarioRide) -> String {
        let local = r.startAtMs / 1000 + Int64(r.utcOffsetMin) * 60
        let day = local / 86_400
        let date = Date(timeIntervalSince1970: Double(day) * 86_400)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.day, .month], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(c.day ?? 0) \(months[max(0, min(11, (c.month ?? 1) - 1))])"
    }
}
