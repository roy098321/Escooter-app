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
    /// N8-3: the soft low tone of a level-2 warning light (no words, no vibration, once per light per ride); draft, final by the sound designer
    case level2Tone = "level2_tone"

    var volume: Float {
        switch self {
        case .connect, .arrival, .pluggedIn, .chargeFull, .saved: return 0.8
        case .rideStart, .rideStartShort, .rideEnd, .rideReplay: return 0.9
        case .batteryPing, .destinationPing, .motorPing: return 1.0
        case .level2Tone: return 0.7
        }
    }

    /// nil = a warning ping (always plays)
    var toggle: SoundToggle? {
        switch self {
        case .connect: return .connect
        case .rideStart, .rideStartShort, .rideEnd, .rideReplay: return .ride
        case .arrival: return .arrival
        case .pluggedIn, .chargeFull, .saved: return .chargingSaving
        case .batteryPing, .destinationPing, .motorPing, .level2Tone: return nil
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

    /// B105: changing the options on an active session does not reliably end the ducking (the music stayed low until the next
    /// line). iOS ends it when the session is deactivated with notifyOthersOnDeactivation; then the ride session reopens unducked.
    /// B109 (hotfix .11): returns false when iOS refused the deactivation (one of our sounds still playing): the duck is still on
    @discardableResult
    static func unduck() -> Bool {
        let s = AVAudioSession.sharedInstance()
        var released = true
        do { try s.setActive(false, options: .notifyOthersOnDeactivation) } catch { released = false }
        try? s.setCategory(category, mode: .spokenAudio, options: rideOptions)
        try? s.setActive(true)
        return released
    }

    /// B110 (hotfix .11): the ride's own session setting, back after a nice sound switched it to ambient while the app was on screen
    static func restoreRide() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(category, mode: .spokenAudio, options: rideOptions)
        try? s.setActive(true)
    }

    static var backgroundModes: [String] { Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [] }
    static var missingFiles: [String] { SoundKind.allCases.filter { $0.url == nil }.map { $0.rawValue } }
}

final class SoundPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = SoundPlayer()

    private var players: [AVAudioPlayer] = []
    private var speakAfter: [ObjectIdentifier: String] = [:]
    /// Which sound each player plays (B107 / B110)
    private var kinds: [ObjectIdentifier: SoundKind] = [:]
    /// B107: a warning tone with no line after it ends its own warning when it finishes
    private var endsWarning: Set<ObjectIdentifier> = []
    /// B109: the duck could not end while a sound played; try again when the last one finishes
    private var pendingRelease = false
    /// B108: a few seconds after the last warning, nothing playing = no warning in flight, whatever the count says
    private var safetyNet: DispatchWorkItem?
    static let safetyNetS: TimeInterval = 20
    private let synth = AVSpeechSynthesizer()
    private(set) var rideSessionOpen = false
    private var warningsInFlight = 0
    private(set) var lastPlayed: (kind: SoundKind, at: Date)?
    private(set) var lastSpoken: String?

    private override init() {
        super.init()
        synth.delegate = self
        // B108: a phone call, Siri or another app's voice can stop our line without a "finished"; after it, start clean
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.resetWarnings(reason: "interruption ended")
        }
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
        guard kind.toggle == nil else { return start(kind) }
        // B107 (hotfix .11): a warning sound on its own (the level-2 tone) lowers the music like any warning, so it must end the
        // duck too when it finishes
        warningsInFlight += 1
        armSafetyNet()
        if start(kind, endsWarning: true) { return true }
        warningDone()
        return false
    }

    @discardableResult
    private func start(_ kind: SoundKind, speaking text: String? = nil, endsWarning ends: Bool = false) -> Bool {
        guard let url = kind.url else { return false }
        prepareSession(for: kind)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        p.volume = kind.volume
        p.delegate = self
        p.prepareToPlay()
        players.append(p)
        kinds[ObjectIdentifier(p)] = kind
        if ends { endsWarning.insert(ObjectIdentifier(p)) }
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
        armSafetyNet()
        Haptics.taps(u.taps)
        if !start(kind, speaking: u.text) { speak(u.text) }
    }

    /// N8-4: a cue sound, then the spoken line (the turn-back steps: the soft tone, or ping-ping); no haptic
    func cue(_ kind: SoundKind, then text: String) {
        warningsInFlight += 1
        armSafetyNet()
        if !start(kind, speaking: text) { speak(text) }
    }

    /// F-35: a plain spoken line ("Riding to Uni, 8 km.") on the same channel as the battery lines: no ping and no haptic
    func say(_ text: String) {
        warningsInFlight += 1
        armSafetyNet()
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
        guard warningsInFlight == 0 else { return }
        releaseDuck()
    }

    /// Gives the music back: outside a ride the session is let go (B105), during a ride it reopens un-ducked. B109: iOS refuses
    /// while one of our sounds still plays, so it is tried again when the last one finishes.
    private func releaseDuck() {
        if players.contains(where: { $0.isPlaying }) {
            pendingRelease = true
            return
        }
        pendingRelease = false
        let released: Bool
        if rideSessionOpen {
            released = RideAudio.unduck()
        } else {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                released = true
            } catch { released = false }
        }
        if !released {
            pendingRelease = true
            Diary.shared.note("voice", "Music not given back yet (the audio session was busy); trying again")
        }
    }

    /// B108: a lost "finished" (a ping that never ended, a line cut by a call) must not keep the music low for the rest of the ride
    private func armSafetyNet() {
        safetyNet?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.warningsInFlight > 0 || self.pendingRelease else { return }
            guard !self.synth.isSpeaking, !self.players.contains(where: { $0.isPlaying }) else {
                self.armSafetyNet()                // still talking: look again later
                return
            }
            self.resetWarnings(reason: "nothing playing \(Int(Self.safetyNetS)) s after the last line")
        }
        safetyNet = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.safetyNetS, execute: work)
    }

    private func resetWarnings(reason: String) {
        guard warningsInFlight > 0 || pendingRelease else { return }
        Diary.shared.note("voice", "Warnings reset (\(reason)): \(warningsInFlight) open")
        warningsInFlight = 0
        speakAfter.removeAll()
        endsWarning.removeAll()
        releaseDuck()
    }

    // MARK: Delegates

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.finished(player) }
    }

    /// B108: a sound that can't be decoded never "finishes"; treat it as finished so its line is still said and the duck ends
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { self.finished(player) }
    }

    private func finished(_ player: AVAudioPlayer) {
        let id = ObjectIdentifier(player)
        guard players.contains(where: { $0 === player }) else { return }
        players.removeAll { $0 === player }
        let kind = kinds.removeValue(forKey: id)
        if let text = speakAfter.removeValue(forKey: id) {
            speak(text)
        } else if endsWarning.remove(id) != nil {
            warningDone()
        } else if pendingRelease, warningsInFlight == 0 {
            releaseDuck()                                   // B109: the sound that blocked it is done
        } else if let kind, kind.toggle != nil, rideSessionOpen, warningsInFlight == 0, !players.contains(where: { $0.isPlaying }) {
            RideAudio.restoreRide()                         // B110: back to the ride's own setting after a nice sound
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.warningDone() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.warningDone() }
    }
}
