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
    /// F-22: the followed route's usual %/km (set when the route is picked up at ride start)
    var usualRoutePctPerKm: Double?
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
            if let db = database {
                let overview = BatteryOverview.load(db, currentPct: input.scooterBatteryPct, connected: true)
                recentPctPerKm = overview.range?.pctPerKm
                reservePct = overview.reservePct
            } else {
                recentPctPerKm = nil
            }
            SoundPlayer.shared.beginRideSession()
        } else if !active, on {
            on = false
            if riding { SoundPlayer.shared.play(.rideEnd) }
            SoundPlayer.shared.endRideSession(after: riding ? 3.0 : 0)
            riding = false
            usualRoutePctPerKm = nil
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
        for u in director.update(voice) { SoundPlayer.shared.warn(u) }

        if screen.arrived, !arrivalPlayed {
            arrivalPlayed = true
            SoundPlayer.shared.play(.arrival)
        }
    }
}
