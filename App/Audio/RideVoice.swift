import CorckieCore
import Foundation
import UIKit

/// F-19 / F-22 (P6-3 chunk 3): turns the live ride into sounds. Once a second `RecorderService` hands over the live input and screen;
/// this opens the ride audio session, plays the start / end / arrival sounds and the P-4 warnings that `LiveVoiceDirector` decides.
/// Main thread only.
final class RideVoice {
    static let shared = RideVoice()

    private var director = LiveVoiceDirector()
    private var on = false
    private var riding = false
    private var arrivalPlayed = false
    private var recentPctPerKm: Double?
    private var reservePct = T.t80ReserveDefaultPct
    /// F-35: "Riding to Uni, 8 km." once after the start and after a change at a stop
    private var announcer = DestinationAnnouncer()
    /// F-22: the followed route's usual %/km (set when the route is picked up at ride start)
    var usualRoutePctPerKm: Double?
    /// V-U1 (batch 3): Level 1 / Level 2 lines of the followed route (nil = the rider's recent rides)
    var routeUsageLines: UsageLines?
    private var recentUsageLines = UsageLines.newRider
    /// Hotfix 03: the followed route's past rides point by point and TODAY's estimate (the time the Where-to chip promised), s
    var routeHistory: RouteHistory?
    var todayS: Double?
    /// H3: the followed route's destination name (the place's own name when it has one)
    var routeName: String?
    /// V09: the learned power limit, and the destination's own place name (arrival line)
    var powerLimitPct: Int?
    var arrivalPlace: String?
    /// V09 timing: the followed route's usual stops; the distance to each one at the last second (to tell ahead from behind)
    var usualStops: [GeoPoint] = [] { didSet { stopDist = [:] } }
    private var stopDist: [Int: Double] = [:]
    private var v09 = V09Director()
    private var arrivalLine = ArrivalLineTracker()
    private var lastPos: (lat: Double, lon: Double)?
    private var course: Double?
    private var lastPct: Double?
    /// Hotfix 03: Wh per 1 % for the sag-proof level (nil = the prior)
    private var whPerPct: Double?
    /// The Start button already played the start sound (and the A3 transition) this moment
    private(set) var startTappedAt: Date?

    private init() {}

    /// Home -> Start: the sound, the firm tap and the animation start in the same frame
    func startTapped() {
        startTappedAt = Date()
        SoundPlayer.shared.play(Self.reduceMotion ? .rideStartShort : .rideStart)
        Haptics.firm()
    }

    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    func update(_ input: LiveInput, screen: LiveScreenState, at t: Double, database: AppDatabase?) {
        let active = input.phase == .starting || input.phase == .riding
        if active, !on {
            on = true
            riding = false
            arrivalPlayed = false
            director.beginRide()
            v09 = V09Director()
            arrivalLine.reset()
            lastPos = nil
            course = nil
            whPerPct = database.map { CalibrationUpdater.current($0).whPerPct }
            if let db = database {
                let overview = BatteryOverview.load(db, currentPct: input.scooterBatteryPct, connected: true)
                recentPctPerKm = overview.range?.pctPerKm
                reservePct = overview.reservePct
                recentUsageLines = RouteFollowLoader.recentUsageLines(database: db)
            } else {
                recentPctPerKm = nil
            }
            SoundPlayer.shared.beginRideSession()
        } else if !active, on {
            on = false
            // V09 arrival line without a saved place: at the ride end, "Arrived, battery at X percent"
            if riding, V09Settings.isOn, let m = arrivalLine.rideEnded(pct: lastPct) { say(m) }
            if riding { SoundPlayer.shared.play(.rideEnd) }
            SoundPlayer.shared.endRideSession(after: riding ? 3.0 : 0)
            riding = false
            usualRoutePctPerKm = nil
            routeUsageLines = nil
            routeHistory = nil
            todayS = nil
            routeName = nil
            usualStops = []
            return
        }
        guard active else { return }
        if input.phase == .riding, !riding {
            riding = true
            // a ride that started by itself (no tap): the same sound with the live view's appearance
            if Date().timeIntervalSince(startTappedAt ?? .distantPast) > 10 {
                SoundPlayer.shared.play(Self.reduceMotion ? .rideStartShort : .rideStart)
            }
        }
        guard input.phase == .riding else { return }

        var route: LiveVoiceInput.RouteLive?
        if let p = screen.routeProgress, let usual = usualRoutePctPerKm {
            route = LiveVoiceInput.RouteLive(name: p.name, routeKm: p.routeKm, alongKm: p.alongKm, usualPctPerKm: usual)
        }
        let voice = LiveVoiceInput(t: t, pct: input.scooterBatteryPct, tempC: input.scooterTempC,
                                   rideKm: (input.rideDistanceM ?? 0) / 1000, recentPctPerKm: recentPctPerKm,
                                   reservePct: reservePct, route: route)
        // V09 on: its engine lines replace the old "Motor hot."
        for u in director.update(voice) where !(V09Settings.isOn && u.alerts == [.motorHot]) { SoundPlayer.shared.warn(u) }

        if screen.arrived, !arrivalPlayed {
            arrivalPlayed = true
            SoundPlayer.shared.play(.arrival)
            if V09Settings.isOn, arrivalPlace != nil, let m = arrivalLine.arrived(place: arrivalPlace, pct: input.scooterBatteryPct) { say(m) }
        }
        if input.scooterBatteryPct != nil { lastPct = input.scooterBatteryPct }
        guard V09Settings.isOn else { return }
        if let lat = input.lat, let lon = input.lon {
            if let p = lastPos {
                let a = GeoPoint(lat: p.lat, lon: p.lon), b = GeoPoint(lat: lat, lon: lon)
                if Geo.distanceM(a, b) >= 8 { course = Self.bearing(a, b); lastPos = (lat, lon) }
            } else {
                lastPos = (lat, lon)
            }
        }
        let v = V09Input(t: t, pct: input.scooterBatteryPct, tempC: input.scooterTempC, rideKm: (input.rideDistanceM ?? 0) / 1000,
                         speedKmh: Double(screen.tiles.speedKmh ?? 0), courseDeg: course,
                         usualPctPerKm: usualRoutePctPerKm ?? recentPctPerKm, reservePct: reservePct,
                         routeKm: screen.routeProgress?.routeKm, alongKm: screen.routeProgress?.alongKm,
                         elapsedS: input.rideElapsedS ?? 0, remainingS: screen.remainingS, powerLimitPct: powerLimitPct,
                         recordingProblem: input.phoneMode || input.formatChanged, usualStopAheadM: stopAhead(input.lat, input.lon),
                         powerW: input.scooterPowerW, currentA: input.scooterCurrentA, whPerPct: whPerPct,
                         history: routeHistory, todayS: todayS, placeName: startPlace,
                         utcOffsetMin: TimeZone.current.secondsFromGMT() / 60)
        var vi = v
        vi.usageLines = usualRoutePctPerKm != nil ? (routeUsageLines ?? recentUsageLines) : recentUsageLines
        for m in v09.update(vi) { say(m, numbers: v09.numbers) }
    }

    /// V09 timing: the nearest usual stop that is getting closer (ahead), m; nil = none known
    private func stopAhead(_ lat: Double?, _ lon: Double?) -> Double? {
        guard let lat, let lon, !usualStops.isEmpty else { return nil }
        let here = GeoPoint(lat: lat, lon: lon)
        var best: Double?
        for (i, s) in usualStops.enumerated() {
            let d = Geo.distanceM(here, s)
            if let before = stopDist[i], d < before - 1, d > 30, best == nil || d < best! { best = d }
            stopDist[i] = d
        }
        return best
    }

    /// V09: one line on the warnings' channel (no ping), logged with the numbers behind it (Hotfix 03)
    private func say(_ m: V09Message, numbers: V09Numbers? = nil) {
        SoundPlayer.shared.say(m.line)
        var why = ""
        if let n = numbers {
            func f(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "-" }
            why = " [km \(f(n.rideKm)) along \(f(n.alongKm)) live \(f(n.livePct)) level \(f(n.levelPct)) start \(f(n.startPct))"
                + " arrival \(f(n.arrivalPct))\(n.stable ? " steady" : "") late \(f(n.lateS)) s]"
        }
        Log.info(source: "voice", "V09: said \"\(m.line)\"" + (m.urgent ? " (urgent)" : " (at a good moment)") + why)
        // the ride summary compares it with what really happened
        var n = numbers ?? V09Numbers()
        if n.t == 0 { n.t = Date().timeIntervalSince1970 }
        V09LineLog.add(V09SaidLine(m, numbers: n), db: AppModel.shared.database)
    }

    /// H3: the start line names the destination of the known route (nil = no route: no start line)
    private var startPlace: String? { todayS == nil ? nil : (arrivalPlace ?? routeName) }

    /// Compass bearing a → b, degrees
    static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLon = (b.lon - a.lon) * .pi / 180
        let la = a.lat * .pi / 180, lb = b.lat * .pi / 180
        let y = sin(dLon) * cos(lb)
        let x = cos(la) * sin(lb) - sin(la) * cos(lb) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Developer: every V09 message once, one after the other (no ride needed)
    func playAllV09() {
        for (i, m) in V09Message.samples.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 4.5) { SoundPlayer.shared.say(m.line) }
        }
    }

    /// F-35: once a second after `update`: the destination as it stands (key, name, distance left); speaks the line when the announcer says so
    func destination(key: String?, name: String?, distanceM: Double?, riding: Bool, at t: Double) {
        guard announcer.update(riding: on && riding, key: key, at: t), let name else { return }
        // H3: on a known route with voice energy updates on, V09 says the full start line instead
        if announcer.lastWasStart, V09Settings.isOn, todayS != nil { return }
        let line = DestinationLive.ridingLine(name: name, distanceM: distanceM)
        SoundPlayer.shared.say(line)
        Log.info(source: "voice", "F-35: said \"\(line)\"")
    }

    /// F-35: another destination was picked at a stop: the F-22 check starts over for it, and the arrival sound can play for it
    func destinationChanged(usualPctPerKm: Double?, usageLines: UsageLines? = nil) {
        usualRoutePctPerKm = usualPctPerKm
        routeUsageLines = usageLines
        director.destinationChanged()
        arrivalPlayed = false
    }
}

/// V09: Settings → Sounds → Voice energy updates (on by default)
enum V09Settings {
    private static let key = "corckie.v09.on"
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
