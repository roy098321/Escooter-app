import AVFoundation
import CorckieCore
import Foundation

/// P6-3 chunk 3 checks, on made-up input (nothing real is read or written):
/// u74 battery 20 / 15 / 10 % warnings and the km-left rounding, u75 F-22 "Will I make it?" rules, u76 the sound files are in the app,
/// u77 the ride audio session and voice settings.
@MainActor
enum P63AliveChecks {
    private final class Expect {
        var notes: [String] = []
        var ok = true
        func callAsFunction(_ condition: Bool, _ what: String) {
            notes.append((condition ? "\u{2713} " : "\u{2717} ") + what)
            if !condition { ok = false }
        }
        var line: String { notes.joined(separator: " \u{00B7} ") }
    }

    static func run() {
        runBattery()
        runDestination()
        runFiles()
        runSession()
    }

    // MARK: u74

    private static func runBattery() {
        let expect = Expect()
        var b = BatteryWarningTracker()
        var spoken: [Int] = []
        var t = 0.0
        for pct in stride(from: 24.0, through: 8.0, by: -0.5) {
            for _ in 0..<10 {
                if let p = b.update(pct: pct, at: t) { spoken.append(p) }
                t += 1
            }
        }
        expect(spoken == [20, 15, 10], "20, 15 and 10 % each once, in order (\(spoken))")
        var bounce = BatteryWarningTracker()
        var early = false
        _ = bounce.update(pct: 22, at: 0)
        for k in 0..<20 {
            if bounce.update(pct: k % 2 == 0 ? 20 : 21, at: Double(1 + k * 10)) != nil { early = true }
        }
        expect(!early, "a bouncing % never fires before it held 30 s")
        var low = BatteryWarningTracker()
        let atStart = low.update(pct: 17, at: 0)
        let next = low.update(pct: 16, at: 60)
        expect(atStart == 17 && next == nil, "a ride starting at 17 % announces it once at the start")
        expect(BatteryRangeSpeech.kmLeft(pct: 20, reservePct: 5, pctPerKm: 2.2) == 6, "6.8 km is spoken as 6 (rounded down)")
        expect(BatteryRangeSpeech.line(percent: 20, kmLeft: 6) == "Battery at twenty percent, about six kilometres left.", "the line reads as agreed")
        expect(BatteryRangeSpeech.line(percent: 10, kmLeft: 1) == "Battery at ten percent, less than two kilometres left.", "under 2 km says less than two")
        let blend = BatteryRangeSpeech.blendedPctPerKm(ridePctPerKm: 4, rideKm: 5, recentPctPerKm: 2) ?? 0
        expect(abs(blend - 3.4) < 1e-9, "after 5 km: 70 % this ride, 30 % the last rides")
        var m = MotorHotTracker()
        let first = m.update(tempC: 90)
        let again = m.update(tempC: 95)
        _ = m.update(tempC: 80)
        let hotAgain = m.update(tempC: 91)
        expect(first && !again && hotAgain, "motor hot: once, and again only after cooling below the level")
        CheckResults.shared.set("u74", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u75

    private static func runDestination() {
        let expect = Expect()
        func input(_ start: Double, _ pct: Double, along: Double = 4, ride: Double = 4) -> DestinationInput {
            DestinationInput(name: "Work", routeKm: 8, alongKm: along, rideKm: ride, startPct: start, pct: pct, usualPctPerKm: 2)
        }
        expect(!DestinationRules.inDoubt(input(40, 30)), "a normal ride is not in doubt")
        expect(DestinationRules.inDoubt(input(40, 18)), "real doubt: ridden enough, 8 % over usual, below the reserve with the margin")
        expect(!DestinationRules.inDoubt(input(24, 18, along: 1, ride: 1)), "too early (1 km of 8) says nothing")
        var d = DestinationTracker()
        let bad = input(40, 18)
        _ = d.update(bad, at: 0)
        let early = d.update(bad, at: 59)
        let on = d.update(bad, at: 61)
        expect(early == nil && on != nil, "it speaks after about 60 s")
        expect(d.update(bad, at: 300) == nil, "and only once")
        expect(DestinationRules.line(name: "Work", verdict: .arrive(pct: 3)) == "Work: arrive with three percent.", "arrive line")
        expect(DestinationRules.line(name: "Work", verdict: .short(km: 2)) == "Work: two kilometres short.", "short line")
        expect(DestinationRules.preRideWarning(name: "Work", usualNeedPct: 40, batteryPct: 45) == "Work needs about 40%, you have 45%", "pre-ride orange line")
        expect(DestinationRules.preRideWarning(name: "Work", usualNeedPct: 40, batteryPct: 80) == nil, "plenty of battery says nothing")
        expect(LiveAlerts.interruptions == [.battery, .destination, .motorHot], "only battery, destination and motor may interrupt")
        CheckResults.shared.set("u75", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u76

    private static func runFiles() {
        let expect = Expect()
        let missing = RideAudio.missingFiles
        expect(missing.isEmpty, "all sound files are in the app" + (missing.isEmpty ? "" : " (missing \(missing))"))
        if let url = SoundKind.rideStart.url, let p = try? AVAudioPlayer(contentsOf: url) {
            expect(abs(p.duration - 0.66) < 0.02, "ride_start is 0.66 s long: \(String(format: "%.2f", p.duration)) s")
            expect(p.numberOfChannels == 2, "stereo")
        } else {
            expect(false, "ride_start loads")
        }
        if let url = SoundKind.destinationPing.url, let p = try? AVAudioPlayer(contentsOf: url) {
            expect(p.duration > 0.3 && p.duration < 1.5, "the destination ping is short: \(String(format: "%.2f", p.duration)) s")
        } else {
            expect(false, "destination_ping loads")
        }
        CheckResults.shared.set("u76", expect.ok ? .pass : .fail, expect.line)
    }

    // MARK: u77

    private static func runSession() {
        let expect = Expect()
        expect(RideAudio.category == .playback, "the ride session is .playback (warnings sound with the silent switch on)")
        expect(RideAudio.warningOptions.contains(.duckOthers) && RideAudio.warningOptions.contains(.mixWithOthers), "a warning ducks and mixes with other audio")
        expect(!RideAudio.rideOptions.contains(.duckOthers), "the open ride session does not lower anyone's music by itself")
        expect(RideAudio.backgroundModes.contains(RideAudio.backgroundMode), "the audio background mode is declared")
        expect(RideAudio.voiceLanguage == "en-US" && abs(RideAudio.voiceRate - 0.5) < 0.001, "voice: en-US at rate 0.5")
        expect(SoundKind.batteryPing.toggle == nil && SoundKind.destinationPing.toggle == nil && SoundKind.motorPing.toggle == nil,
               "the warnings have no switch")
        expect(SoundKind.rideStart.toggle == .ride && SoundKind.connect.toggle == .connect && SoundKind.arrival.toggle == .arrival,
               "connect, ride and arrival have one switch each")
        expect(!SoundPlayer.shared.rideSessionOpen, "no ride: the audio session is not held")
        CheckResults.shared.set("u77", expect.ok ? .pass : .fail, expect.line)
    }
}
