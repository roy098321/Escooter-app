import CorckieCore
import Foundation
import UIKit

/// N10-2 / N10-3 (batch 10): the only faults spoken during a ride. L3 = the warning ping, the voice line and a vibration.
/// F2: the 2nd and the 4th power cut in one ride. F3: a brake run on a ride after one was already found, right after the braking.
/// A new rider (still learning) hears nothing (HARSH RULE). The scooter is only read.
final class LiveFaultWatch {
    static let shared = LiveFaultWatch()

    private var assembler = FrameAssembler()
    private var tracker = LiveFaultTracker()
    private var voice: LiveFaultVoice?
    private var wasRiding = false
    /// The red ride-screen lights, on for the rest of the ride once the voice spoke
    private(set) var powerCutLight = false
    private(set) var brakeFaultLight = false

    private init() {}

    /// Every scooter packet (main thread)
    func packet(_ bytes: [UInt8], at t: Double) {
        FaultSwitchOn.shared.packet(bytes, at: t)
        let riding = RecorderService.shared.rideActive && !RecorderService.shared.simActive
        if riding != wasRiding {
            wasRiding = riding
            if riding { start() } else { voice = nil }
            powerCutLight = false
            brakeFaultLight = false
        }
        guard riding, var v = voice, let f = assembler.ingest(bytes, at: t) else { return }
        for e in tracker.frame(f) {
            let line: String?
            switch e {
            case .powerCut:
                line = v.powerCut()
                if line != nil { powerCutLight = true }
            case .brakeRunEnded:
                line = v.brakeRunEnded()
                if line != nil { brakeFaultLight = true }
            }
            if let line { speak(line) }
        }
        voice = v
    }

    private func start() {
        assembler = FrameAssembler()
        tracker = LiveFaultTracker()
        let db = AppModel.shared.database
        let book = FaultStore.load(db, FaultStore.bookKey, as: FaultBook.self) ?? FaultBook()
        let id = db.flatMap { ScooterRecord.latest(in: $0)?.id } ?? "scooter"
        let f3 = book.baseline(id, .f3BrakeCut)
        let foundBefore = f3.lastAlertDay != nil || FaultStore.records(db).contains { $0.kind == .f3BrakeCut && $0.scooterId == id }
        voice = LiveFaultVoice(learned: book.baseline(id, .f2PowerCut).learned, brakeFoundBefore: foundBefore)
    }

    private func speak(_ line: String) {
        SoundPlayer.shared.cue(.batteryPing, then: line)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        Log.info(source: "voice", "N10: said \"\(line)\" (fault, L3)")
    }
}
