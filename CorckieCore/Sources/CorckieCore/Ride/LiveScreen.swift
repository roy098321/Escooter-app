import Foundation

// M1-12: everything the live ride screen decides, pure and unit tested (the SwiftUI view only draws it).
// Safety rules (STATES, CONCEPT C24, M1_PLAN D2): no tab bar and no navigation while a ride is on; speed and
// battery tiles never hidden by a banner; at most one banner, tappable only below 5 km/h; SLOW red above 45 and
// clears below 43; GPS speed greyed and labelled; "~N% est." in phone mode; "Ready" (D2): the view opened before
// the wheel moves shows the map, battery and speed 0, no clock, no stop button, and only there can it be closed.

public enum LiveMode: String, Equatable, Sendable {
    /// Opened from the "Going for a ride?" notification: no ride yet
    case ready
    /// Stage 1: the ride row exists, the "starting\u{2026}" dot shows, "Not riding" cancels silently
    case starting
    case riding
}

public struct LiveScreenState: Equatable, Sendable {
    public var mode: LiveMode
    public var tiles: LiveState
    public var banner: BannerQueue.Shown?
    public var bannerText: String?
    /// "Same ride?" shows Yes / No instead of one tap target
    public var bannerIsSameRide: Bool
    /// "No GPS" is left out while its banner shows
    public var chips: [LiveChip]
    public var showClock: Bool
    public var clockText: String
    /// Only "Ready" can be closed (to Home); a ride has no back button
    public var canClose: Bool
    public var showHoldToEnd: Bool
    public var showNotRiding: Bool
    /// Phone mode: the path keeps drawing dashed
    public var dashedPath: Bool
    /// No GPS for 10 s: the dot freezes, greyed
    public var dotGreyed: Bool
}

public enum LiveScreenLogic {
    /// The full-screen cover is up while a ride is on, or when "Ready" was asked for; the tab bar is never visible then.
    public static func coverShown(phase: RidePhase, readyRequested: Bool) -> Bool {
        phase == .starting || phase == .riding || readyRequested
    }

    public static func clock(_ seconds: Double?) -> String {
        guard let s = seconds, s >= 0 else { return "0:00" }
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Keeps the speed-warning hysteresis and the banner queue between updates (about once a second).
public struct LiveScreenDriver: Sendable {
    private var builder = LiveStateBuilder()
    private var banners = BannerQueue()
    private var lastPhase: RidePhase = .idle
    private var sameRideWasOffered = false

    public init() {}

    private static func active(_ p: RidePhase) -> Bool { p == .starting || p == .riding }

    public mutating func update(_ input: LiveInput, at t: Double) -> LiveScreenState {
        let mode: LiveMode = input.phase == .riding ? .riding : (input.phase == .starting ? .starting : .ready)
        let active = Self.active(input.phase)
        if active && !Self.active(lastPhase) {
            banners.beginRide(messages: [])
            builder.reset()
            sameRideWasOffered = false
        } else if !active && Self.active(lastPhase) {
            banners = BannerQueue()
            builder.reset()
        }
        lastPhase = input.phase

        let tiles = builder.update(input)
        var shown: BannerQueue.Shown?
        if active {
            banners.setActive(.disconnected, input.phoneMode, at: t)
            banners.setActive(.noGps, tiles.chips.contains(.noGps), at: t)
            if let temp = input.scooterTempC { banners.feedHeat(tempC: temp, at: t) }
            if input.sameRideOffered && !sameRideWasOffered { banners.raise(.sameRide, at: t) }
            sameRideWasOffered = input.sameRideOffered
            shown = banners.tick(at: t, speedKmh: Double(tiles.speedKmh ?? 0))
            if shown?.banner == .sameRide && !input.sameRideOffered {
                // answered (or the offer ran out): take it off the screen, whatever the speed
                banners.dismissCurrent(speedKmh: 0)
                shown = banners.tick(at: t, speedKmh: Double(tiles.speedKmh ?? 0))
            }
        }

        var chips = tiles.chips
        if !active {
            chips = chips.filter { $0 == .offlineMap }
        } else if shown?.banner == .noGps {
            chips = chips.filter { $0 != .noGps }
        }
        let text: String? = shown.map { s in
            (s.banner == .disconnected && input.formatChanged) ? "Scooter data format changed" : s.banner.text
        }
        return LiveScreenState(mode: mode, tiles: tiles, banner: shown, bannerText: text,
                               bannerIsSameRide: shown?.banner == .sameRide,
                               chips: chips, showClock: active, clockText: LiveScreenLogic.clock(input.rideElapsedS),
                               canClose: mode == .ready, showHoldToEnd: active, showNotRiding: mode == .starting,
                               dashedPath: active && input.phoneMode,
                               dotGreyed: tiles.chips.contains(.noGps))
    }

    /// The rider taps a banner away (or answers it). Refused (false) at 5 km/h or more.
    @discardableResult
    public mutating func tapBanner(speedKmh: Double) -> Bool {
        banners.dismissCurrent(speedKmh: speedKmh)
    }
}

/// The stop button: a tap does nothing, only a hold of T19 (1 s) ends the ride.
public struct HoldToEnd: Equatable, Sendable {
    public private(set) var startedAt: Double?
    public let holdS: Double

    public init(holdS: Double = T.t19EndHoldS) { self.holdS = holdS }

    public mutating func begin(at t: Double) { startedAt = t }
    public mutating func cancel() { startedAt = nil }

    /// 0...1 for the ring around the button
    public func progress(at t: Double) -> Double {
        guard let s = startedAt else { return 0 }
        return min(1, max(0, (t - s) / holdS))
    }

    public func completed(at t: Double) -> Bool {
        guard let s = startedAt else { return false }
        return t - s >= holdS
    }
}

/// The ride's path so far, in runs of one speed colour and one line style (solid, or dashed in phone mode).
public struct LivePath: Equatable, Sendable {
    public struct Coord: Equatable, Sendable {
        public var lat: Double
        public var lon: Double

        public init(lat: Double, lon: Double) {
            self.lat = lat
            self.lon = lon
        }
    }

    public struct Segment: Equatable, Sendable {
        /// 0 (slowest) ... `bucketCount - 1`
        public var bucket: Int
        public var dashed: Bool
        public var coords: [Coord]
    }

    public static let bucketCount = 5
    /// A new point must be this far from the last one
    public static let minStepM = 3.0
    public private(set) var segments: [Segment] = []
    private var last: Coord?

    public init() {}

    public static func bucket(speedKmh: Double) -> Int {
        switch speedKmh {
        case ..<10: return 0
        case ..<20: return 1
        case ..<30: return 2
        case ..<40: return 3
        default: return 4
        }
    }

    public var pointCount: Int { segments.reduce(0) { $0 + $1.coords.count } }

    public mutating func reset() {
        segments = []
        last = nil
    }

    public mutating func add(lat: Double, lon: Double, speedKmh: Double, dashed: Bool) {
        let c = Coord(lat: lat, lon: lon)
        if let l = last, Self.metres(l, c) < Self.minStepM { return }
        let b = Self.bucket(speedKmh: speedKmh)
        if var s = segments.last, s.bucket == b, s.dashed == dashed {
            s.coords.append(c)
            segments[segments.count - 1] = s
        } else {
            // the new run starts where the old one ended, so the line has no hole
            segments.append(Segment(bucket: b, dashed: dashed, coords: (last.map { [$0] } ?? []) + [c]))
        }
        last = c
    }

    static func metres(_ a: Coord, _ b: Coord) -> Double {
        let dLat = (b.lat - a.lat) * 111_320
        let dLon = (b.lon - a.lon) * 111_320 * cos(a.lat * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}
