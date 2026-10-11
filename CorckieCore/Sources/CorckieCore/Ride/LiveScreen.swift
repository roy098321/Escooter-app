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
    /// M2-06: "Work . arrive ~8:56 . 9 min left" while a route is followed
    public var arrival: ArrivalStrip? = nil
    /// M2-08: GPS lost on a followed route: the dot moves by wheel distance and is drawn hollow at `dotOverride`
    public var dotHollow: Bool = false
    public var dotOverride: LivePath.Coord? = nil
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

/// The arrival time (epoch seconds) the screen showed when 25 / 50 / 75% of the followed route was done.
public struct EtaMark: Equatable, Sendable {
    public static let percents = [25, 50, 75]
    public var percent: Int
    public var arrivalS: Double
    public var atS: Double

    public init(percent: Int, arrivalS: Double, atS: Double) {
        self.percent = percent
        self.arrivalS = arrivalS
        self.atS = atS
    }
}

/// Keeps the speed-warning hysteresis and the banner queue between updates (about once a second).
public struct LiveScreenDriver: Sendable {
    private var builder = LiveStateBuilder()
    private var banners = BannerQueue()
    private var lastPhase: RidePhase = .idle
    private var sameRideWasOffered = false
    private var follower: RouteFollower?
    private var arrivalDisplay = ArrivalDisplay()
    private var utcOffsetMin = 0
    private var returnWarning: String?
    private var prompter: ChoicePrompter?
    private var activePromptId: String?
    private var promptText: String?
    /// Choice-point prompts shown in the ride that just ended (or the running one)
    public private(set) var choicePromptsShown = 0
    public private(set) var choiceReplans = 0
    /// T-00 (prediction log, Q-E): the arrival time shown when the rider passed 25 / 50 / 75% of the followed route
    public private(set) var etaMarks: [EtaMark] = []

    public init() {}

    /// M2-06: the route this ride follows (Where to?), or nil. Set before the ride starts or while it runs.
    /// `returnWarning` (Q9): one line shown once at ride start when the way back will not fit (it counts in the 2 start messages).
    public mutating func follow(_ route: RouteFollower?, utcOffsetMin: Int = 0, returnWarning: String? = nil, prompts: ChoicePrompter? = nil) {
        self.returnWarning = returnWarning
        self.prompter = route == nil ? nil : prompts
        activePromptId = nil
        promptText = nil
        choicePromptsShown = 0
        choiceReplans = 0
        etaMarks = []
        if returnWarning != nil, Self.active(lastPhase) { banners.raise(.returnCheck, at: 0) }
        follower = route
        self.utcOffsetMin = utcOffsetMin
        arrivalDisplay = ArrivalDisplay()
    }

    public var isFollowing: Bool { follower != nil }
    /// The path being followed (changes after a quiet re-plan, M6-02)
    public var followedPath: [GeoPoint]? { follower?.path }
    /// Prompts shown so far in the running ride, or in the last one
    public var promptsShownNow: Int { prompter?.shown ?? choicePromptsShown }
    public var choiceReplansNow: Int { prompter?.replans ?? choiceReplans }

    private static func active(_ p: RidePhase) -> Bool { p == .starting || p == .riding }

    public mutating func update(_ input: LiveInput, at t: Double) -> LiveScreenState {
        let mode: LiveMode = input.phase == .riding ? .riding : (input.phase == .starting ? .starting : .ready)
        let active = Self.active(input.phase)
        if active && !Self.active(lastPhase) {
            banners.beginRide(messages: returnWarning == nil ? [] : [.returnCheck])
            builder.reset()
            sameRideWasOffered = false
        } else if !active && Self.active(lastPhase) {
            banners = BannerQueue()
            builder.reset()
            follower = nil
            returnWarning = nil
            choicePromptsShown = prompter?.shown ?? choicePromptsShown
            choiceReplans = prompter?.replans ?? choiceReplans
            prompter = nil
            activePromptId = nil
            promptText = nil
        }
        lastPhase = input.phase

        let tiles = builder.update(input)
        // the follower first: the choice-point prompt (M6-02) needs where the rider is on the path
        var step: RouteFollower.Step?
        var prompt: ChoicePrompt?
        if input.phase == .riding, var f = follower {
            let pos = (input.lat != nil && input.lon != nil) ? GeoPoint(lat: input.lat!, lon: input.lon!) : nil
            let fresh = input.secondsWithoutGps == 0
            var s = f.update(position: pos, gpsFresh: fresh, rideDistanceM: input.rideDistanceM, elapsedS: input.rideElapsedS ?? 0)
            if var p = prompter {
                let u = p.update(position: pos, gpsFresh: fresh, alongM: s.alongM, offPath: s.offPath,
                                 speedMps: Double(tiles.speedKmh ?? 0) / 3.6)
                prompter = p
                prompt = u.prompt
                if let np = u.newPath, var nf = RouteFollower(destinationName: f.destinationName, path: np, todayS: f.todayS) {
                    s = nf.update(position: pos, gpsFresh: fresh, rideDistanceM: input.rideDistanceM, elapsedS: input.rideElapsedS ?? 0)
                    f = nf
                }
            }
            follower = f
            step = s
        }
        var shown: BannerQueue.Shown?
        if active {
            if let p = prompt {
                if p.id != activePromptId {
                    banners.clear(.choicePoint)
                    banners.hold(.choicePoint, true)
                    banners.raise(.choicePoint, at: t)
                    activePromptId = p.id
                }
                promptText = p.text
            } else if activePromptId != nil {
                banners.hold(.choicePoint, false)
                banners.clear(.choicePoint)
                activePromptId = nil
                promptText = nil
            }
            banners.setActive(.disconnected, input.phoneMode, at: t)
            banners.setActive(.noGps, tiles.chips.contains(.noGps) && !input.phoneGpsOff, at: t)
            banners.setActive(.phoneBatteryLow, input.phoneGpsOff, at: t)           // M6-06: phone battery < 10%, GPS off
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
        let text: String? = shown.map { (s: BannerQueue.Shown) -> String in
            if s.banner == .returnCheck, let w = returnWarning { return w }
            if s.banner == .choicePoint, let pt = promptText { return pt }
            if s.banner == .noGps && input.locationDenied { return "No GPS \u{00B7} location is off for CorckieApp" }     // M6-06: permission revoked
            return (s.banner == .disconnected && input.formatChanged) ? "Scooter data format changed" : s.banner.text
        }
        var arrival: ArrivalStrip?
        var dotOverride: LivePath.Coord?
        if let step = step, let f = follower {
            let shown = arrivalDisplay.show(remainingS: step.remainingS, nowS: t)
            arrival = ArrivalStrip(text: ArrivalStrip.text(destination: f.destinationName, arrivalS: shown, nowS: t, utcOffsetMin: utcOffsetMin),
                                   offRoute: step.offPath, deadReckoned: step.deadReckoned)
            if step.deadReckoned, let d = step.dot { dotOverride = LivePath.Coord(lat: d.lat, lon: d.lon) }
            if !step.offPath {
                let done = f.totalM > 0 ? step.alongM / f.totalM * 100 : 0
                for p in EtaMark.percents where done >= Double(p) && !etaMarks.contains(where: { $0.percent == p }) {
                    etaMarks.append(EtaMark(percent: p, arrivalS: shown, atS: t))
                }
            }
        }
        var state = LiveScreenState(mode: mode, tiles: tiles, banner: shown, bannerText: text,
                               bannerIsSameRide: shown?.banner == .sameRide,
                               chips: chips, showClock: active, clockText: LiveScreenLogic.clock(input.rideElapsedS),
                               canClose: mode == .ready, showHoldToEnd: active, showNotRiding: mode == .starting,
                               dashedPath: active && input.phoneMode,
                               dotGreyed: tiles.chips.contains(.noGps))
        state.arrival = arrival
        state.dotOverride = dotOverride
        state.dotHollow = dotOverride != nil
        if dotOverride != nil { state.dotGreyed = false }
        return state
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
