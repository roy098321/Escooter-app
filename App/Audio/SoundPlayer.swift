import AVFoundation
import CorckieCore
import Foundation
import UIKit

// F-19 / P6-3 chunk 3: the app's own sounds (App/Resources/Sounds) and the spoken ride warnings.
// N7-12 (batch 7): one sound family on a G→D motif (synth drafts; a sound designer makes the finals): connect, ride start (+ short),
// ride replay (its length follows `RouteDraw`), ride end, arrival, plugged in, charge full, saved. ONE warning sound for battery,
// destination and motor (the spoken line says which). "Going for a ride?" (chime2_kickoff) is unchanged.
// Warnings (battery 20 / 15 / 10 %, F-22, motor hot) are P-4 interruptions: they play even with the silent switch on and whatever the
// sound toggles say. Connect, ride start / end and arrival are the "nice" sounds: they follow the silent switch and a toggle each.
// Background audio exists only while a ride is running: the session is activated at ride start and given back at ride end.

enum SoundKind: String, CaseIterable {
    case connect
    case rideStart = "ride_start"
    case rideStartShort = "ride_start_short"     // Reduce Motion: the transition takes 0.2 s
    case rideEnd = "ride_end"
    case batteryPing = "battery_ping"
    case arrival
    case destinationPing = "destination_ping"
    case motorPing = "motor_ping"
    // N7-12
    case rideReplay = "ride_replay"
    case pluggedIn = "plugged_in"
    case chargeFull = "charge_full"
    case saved

    var volume: Float {
        switch self {
        case .connect, .arrival, .pluggedIn, .chargeFull, .saved: return 0.8
        case .rideStart, .rideStartShort, .rideEnd, .rideReplay: return 0.9
        case .batteryPing, .destinationPing, .motorPing: return 1.0
        }
    }

    /// nil = a warning ping (always plays)
    var toggle: SoundToggle? {
        switch self {
        case .connect: return .connect
        case .rideStart, .rideStartShort, .rideEnd, .rideReplay: return .ride
        case .arrival: return .arrival
        case .pluggedIn, .chargeFull, .saved: return .chargingSaving
        case .batteryPing, .destinationPing, .motorPing: return nil
        }
    }

    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "wav") }
}

/// Settings -> Sounds: one switch each, on by default
enum SoundToggle: String, CaseIterable {
    case connect, ride, arrival
    /// N7-12: plugged in, charge full, saved
    case chargingSaving = "charging"

    var title: String {
        switch self {
        case .connect: return "Scooter connected"
        case .ride: return "Ride start and end"
        case .arrival: return "Arrival at your destination"
        case .chargingSaving: return "Charging and saving"
        }
    }

    var key: String { "sounds.\(rawValue)" }
    var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    func set(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }
}

/// The audio session as the ride needs it (checked by the lab app).
enum RideAudio {
    static let category = AVAudioSession.Category.playback
    /// The ride keeps the session open without lowering anyone's music
    static let rideOptions: AVAudioSession.CategoryOptions = [.mixWithOthers]
    /// A warning ducks other audio while it is spoken
    static let warningOptions: AVAudioSession.CategoryOptions = [.duckOthers, .mixWithOthers]
    static let voiceLanguage = "en-US"
    static let voiceRate: Float = 0.5
    static let backgroundMode = "audio"

    static var backgroundModes: [String] { Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [] }
    static var missingFiles: [String] { SoundKind.allCases.filter { $0.url == nil }.map { $0.rawValue } }
}

final class SoundPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = SoundPlayer()

    private var players: [AVAudioPlayer] = []
    private var speakAfter: [ObjectIdentifier: String] = [:]
    private let synth = AVSpeechSynthesizer()
    private(set) var rideSessionOpen = false
    private var warningsInFlight = 0
    private(set) var lastPlayed: (kind: SoundKind, at: Date)?
    private(set) var lastSpoken: String?

    private override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Session (only while a ride runs)

    private var pendingEnd: DispatchWorkItem?

    func beginRideSession() {
        pendingEnd?.cancel()
        pendingEnd = nil
        guard !rideSessionOpen else { return }
        rideSessionOpen = true
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(RideAudio.category, mode: .spokenAudio, options: RideAudio.rideOptions)
        try? s.setActive(true)
    }

    /// Gives the session back, after the ride-end sound has played out when `after` is set
    func endRideSession(after delay: TimeInterval = 0) {
        pendingEnd?.cancel()
        if delay > 0 {
            let work = DispatchWorkItem { [weak self] in self?.endRideSession() }
            pendingEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }
        guard rideSessionOpen else { return }
        rideSessionOpen = false
        warningsInFlight = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Plain sounds

    /// Plays one of the nice sounds when its switch is on. Returns whether it started.
    @discardableResult
    func play(_ kind: SoundKind) -> Bool {
        if let t = kind.toggle, !t.isOn { return false }
        return start(kind)
    }

    /// N7-12: the ride replay sound, faded out so it lasts as long as the route draws (`RouteDraw.durationS`)
    @discardableResult
    func play(_ kind: SoundKind, lastingS: Double) -> Bool {
        guard play(kind), let p = players.last else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, lastingS - 0.15)) { p.setVolume(0, fadeDuration: 0.35) }
        return true
    }

    @discardableResult
    private func start(_ kind: SoundKind, speaking text: String? = nil) -> Bool {
        guard let url = kind.url else { return false }
        prepareSession(for: kind)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        p.volume = kind.volume
        p.delegate = self
        p.prepareToPlay()
        players.append(p)
        if let text { speakAfter[ObjectIdentifier(p)] = text }
        p.play()
        lastPlayed = (kind, Date())
        return true
    }

    /// Outside a ride the plain ambient category follows the silent switch. During a ride the session is `.playback` (so warnings are heard
    /// with the switch on); the nice sounds ask for the ambient behaviour while the app is on screen so they still follow the switch.
    private func prepareSession(for kind: SoundKind) {
        let s = AVAudioSession.sharedInstance()
        if kind.toggle == nil {
            try? s.setCategory(RideAudio.category, mode: .spokenAudio, options: RideAudio.warningOptions)
            try? s.setActive(true)
        } else if !rideSessionOpen || UIApplication.shared.applicationState == .active {
            try? s.setCategory(.ambient, mode: .default, options: [])
            try? s.setActive(true)
        }
    }

    // MARK: Warnings

    /// A P-4 warning: the ping, then the voice line, with a haptic pattern alongside.
    func warn(_ u: LiveUtterance) {
        let kind: SoundKind = u.ping == .destination ? .destinationPing : (u.ping == .motor ? .motorPing : .batteryPing)
        warningsInFlight += 1
        Haptics.taps(u.taps)
        if !start(kind, speaking: u.text) { speak(u.text) }
    }

    /// F-35: a plain spoken line ("Riding to Uni, 8 km.") on the same channel as the battery lines: no ping and no haptic
    func say(_ text: String) {
        warningsInFlight += 1
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(RideAudio.category, mode: .spokenAudio, options: RideAudio.warningOptions)
        try? s.setActive(true)
        speak(text)
    }

    private func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: RideAudio.voiceLanguage)
        u.rate = RideAudio.voiceRate
        u.volume = 1
        lastSpoken = text
        Diary.shared.note("voice", text)   // B81
        synth.speak(u)
    }

    private func warningDone() {
        warningsInFlight = max(0, warningsInFlight - 1)
        guard warningsInFlight == 0, rideSessionOpen else { return }
        // un-duck the music; the session stays open for the ride
        try? AVAudioSession.sharedInstance().setCategory(RideAudio.category, mode: .spokenAudio, options: RideAudio.rideOptions)
    }

    // MARK: Delegates

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            let id = ObjectIdentifier(player)
            self.players.removeAll { $0 === player }
            if let text = self.speakAfter.removeValue(forKey: id) { self.speak(text) }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.warningDone() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.warningDone() }
    }
}
