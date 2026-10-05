import Foundation

/// M1-07: what the live ride view shows, worked out from what the ride engine (M1-03 / M1-04 / M1-05)
/// knows. The engine fills one `LiveInput` per update (about once a second) and the view only reads the
/// `LiveState`, so every safety rule lives here and is unit tested (CONCEPT: speed >= 76 pt, SLOW above
/// 45 / clears below 43, GPS speed labelled, battery "~N% est.", No GPS chip after 10 s).

public enum LiveSpeedSource: Equatable, Sendable {
    case scooter
    case gps
}

public enum LiveChip: Equatable, Sendable {
    case noGps
    case offlineMap
}

/// The engine's side of the contract (M1-03 / M1-04 / M1-05 fill it).
public struct LiveInput: Equatable, Sendable {
    /// Fresh scooter speed, nil when the scooter gives no reading right now
    public var scooterSpeedKmh: Double?
    /// GPS speed, already the 3-s median (G1); nil without a usable fix
    public var gpsSpeedKmh: Double?
    /// Scooter link up and its readings trusted (not in phone mode)
    public var scooterLinked: Bool
    /// Scooter battery reading in percent
    public var scooterBatteryPct: Double?
    /// Phone-mode estimate (T49), shown as "~N% est."
    public var estimatedBatteryPct: Double?
    /// Ride start stage 1 reached but the ride is not confirmed yet ("starting…")
    public var starting: Bool
    /// Seconds without a good GPS fix (0 while fixes arrive)
    public var secondsWithoutGps: Double
    /// Map tiles not available (no internet)
    public var mapOffline: Bool
    /// M1-12: where the engine is: idle / ready (no ride yet) / starting / riding
    public var phase: RidePhase = .riding
    /// Scooter temperature while the link is live (motor heat banners)
    public var scooterTempC: Double?
    /// Phone mode: the scooter readings are gone (disconnected for ~5 s, or the format changed)
    public var phoneMode: Bool = false
    /// The G1b format watch tripped (banner "Scooter data format changed")
    public var formatChanged: Bool = false
    /// "Same ride?" is waiting for an answer
    public var sameRideOffered: Bool = false
    /// Newest GPS fix (may be old: the dot freezes)
    public var lat: Double?
    public var lon: Double?
    /// Seconds since the ride row started (the clock), nil without a ride
    public var rideElapsedS: Double?
    /// M2-08: wheel distance of this ride so far, m (moves the dot along a followed route when GPS is lost)
    public var rideDistanceM: Double?

    public init(scooterSpeedKmh: Double? = nil, gpsSpeedKmh: Double? = nil, scooterLinked: Bool = true,
                scooterBatteryPct: Double? = nil, estimatedBatteryPct: Double? = nil, starting: Bool = false,
                secondsWithoutGps: Double = 0, mapOffline: Bool = false, phase: RidePhase = .riding,
                scooterTempC: Double? = nil, phoneMode: Bool = false, formatChanged: Bool = false,
                sameRideOffered: Bool = false, lat: Double? = nil, lon: Double? = nil, rideElapsedS: Double? = nil, rideDistanceM: Double? = nil) {
        self.rideDistanceM = rideDistanceM
        self.phase = phase
        self.scooterTempC = scooterTempC
        self.phoneMode = phoneMode
        self.formatChanged = formatChanged
        self.sameRideOffered = sameRideOffered
        self.lat = lat
        self.lon = lon
        self.rideElapsedS = rideElapsedS
        self.scooterSpeedKmh = scooterSpeedKmh
        self.gpsSpeedKmh = gpsSpeedKmh
        self.scooterLinked = scooterLinked
        self.scooterBatteryPct = scooterBatteryPct
        self.estimatedBatteryPct = estimatedBatteryPct
        self.starting = starting
        self.secondsWithoutGps = secondsWithoutGps
        self.mapOffline = mapOffline
    }
}

public struct LiveState: Equatable, Sendable {
    /// Whole km/h to show; nil = no speed at all (phone mode without GPS)
    public var speedKmh: Int?
    public var speedSource: LiveSpeedSource
    /// "GPS" whenever the shown speed is not the scooter's (always set in phone mode, P3 D3)
    public var speedLabel: String?
    /// GPS speed is greyed
    public var speedGreyed: Bool
    public var batteryPct: Int?
    /// "91%", "~55% est." or "–"
    public var batteryText: String
    public var batteryEstimated: Bool
    /// Red + "SLOW"
    public var slow: Bool
    public var slowText: String?
    public var chips: [LiveChip]
    /// The "starting…" dot
    public var showStartingDot: Bool
}

/// Keeps the speed-warning hysteresis between updates.
public struct LiveStateBuilder: Equatable, Sendable {
    public private(set) var warning = SpeedWarning()

    public init() {}

    public mutating func update(_ input: LiveInput) -> LiveState {
        let onScooter = input.scooterLinked && input.scooterSpeedKmh != nil
        let speed: Double?
        let source: LiveSpeedSource
        if onScooter {
            speed = input.scooterSpeedKmh
            source = .scooter
        } else {
            source = .gps
            if let g = input.gpsSpeedKmh {
                speed = g < T.t29GpsZeroKmh ? 0 : g      // T29: below 5 km/h shown as 0
            } else {
                speed = nil
            }
        }
        // no speed at all: the warning keeps its state (nothing to compare, nothing flickers)
        let slow = speed.map { warning.update(speedKmh: $0) } ?? warning.isOn

        let battery: Double?
        let estimated: Bool
        if input.scooterLinked, let b = input.scooterBatteryPct {
            battery = b
            estimated = false
        } else if let e = input.estimatedBatteryPct {
            battery = e
            estimated = true
        } else if let b = input.scooterBatteryPct {
            battery = b          // last scooter reading while the link is down: better than nothing, but unconfirmed
            estimated = !input.scooterLinked
        } else {
            battery = nil
            estimated = false
        }
        let batteryInt = battery.map { Int($0.rounded()) }
        let text: String
        if let b = batteryInt { text = estimated ? "~\(b)% est." : "\(b)%" } else { text = "–" }

        var chips: [LiveChip] = []
        if input.secondsWithoutGps >= T.t100NoGpsChipS { chips.append(.noGps) }
        if input.mapOffline { chips.append(.offlineMap) }

        return LiveState(speedKmh: speed.map { Int($0.rounded()) }, speedSource: source,
                         speedLabel: source == .gps ? "GPS" : nil, speedGreyed: source == .gps,
                         batteryPct: batteryInt, batteryText: text, batteryEstimated: estimated,
                         slow: slow, slowText: slow ? "SLOW" : nil, chips: chips,
                         showStartingDot: input.starting)
    }

    public mutating func reset() { warning.reset() }
}
