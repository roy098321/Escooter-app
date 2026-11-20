import CorckieCore
import Foundation

/// Batch 10 (maintenance) check u202, on made-up readings only: the HARSH RULE gate (a new rider hears nothing; a healthy run stays
/// quiet; a faulty ride is caught), one fault per summary, the in-ride voice lines, the parts list without "OK", the history counts
/// and both report languages. The real data is never touched.
@MainActor
enum B110Checks {
    typealias Expect = B101LateChecks.Expect

    private static func frame(_ t: Double, kmh: Double = 20, v: Double, a: Double, odo: Double) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh; f.voltage = v; f.currentA = a; f.temperatureC = 40; f.odometerKm = odo; f.ageA = 0.2; f.ageB = 0.2
        return f
    }

    private static func ride(_ k: Int) -> [ScooterFrame] {
        (0..<900).map { j in
            let i = 12 + 10 * sin(Double(j) / 7)
            return frame(Double(j), v: 52 - i * 0.065, a: i, odo: 100 + Double(k) * 5 + Double(j) / 300)
        }
    }

    static func run() {
        let expect = Expect()
        var book = FaultBook(), heat = HeatBook()
        var quiet = true
        var prev: Double?
        for k in 0..<15 {
            let f = ride(k)
            let rep = AfterRideFaults.run(RideFaultInput(scooterId: "LAB", firmware: "1", frames: f, day: k, ruleOuts: FaultRuleOuts(airC: 20),
                                                         previousOdoKm: prev), book: &book, heat: &heat)
            if !rep.findings.isEmpty { quiet = false }
            prev = f.last?.odometerKm
        }
        expect(quiet, "15 healthy rides: no finding (the first 10 only learn)")
        var bad = ride(15)
        bad[400].shuttingDown = true
        for j in 600..<610 { bad[j].brake = true }
        let rep = AfterRideFaults.run(RideFaultInput(scooterId: "LAB", firmware: "1", frames: bad, day: 15, ruleOuts: FaultRuleOuts(airC: 20),
                                                     previousOdoKm: prev), book: &book, heat: &heat)
        expect(Set(rep.findings.map(\.kind)) == [.f2PowerCut, .f3BrakeCut] && rep.show?.kind.level == .red,
               "a power cut and a brake run are caught; one red pop-up")
        var voice = LiveFaultVoice(learned: true, brakeFoundBefore: false)
        _ = voice.powerCut()
        expect(voice.powerCut() == FaultCopy.voicePowerCut2, "2nd cut in a ride: \(FaultCopy.voicePowerCut2)")
        let rows = MaintParts.rows(open: [FaultRecord(kind: .f6Heat, scooterId: "LAB", value: 12, day: 1, odoKm: 10)], reminders: [],
                                   ridesLeft: [:], batteryLine: nil)
        expect(rows.first?.part == .motor && !rows.contains { $0.line.contains("OK") }, "an issue card on top; never OK")
        expect(MaintParts.homeLine(MaintParts.rows(open: [], reminders: [], ridesLeft: [:], batteryLine: nil)) == nil, "nothing on Home when all is quiet")
        let h = MaintHistory.entries(logged: [LoggedWork(what: .replacedPads, scooterId: "LAB", day: 3, odoKm: 20)],
                                     faults: [FaultRecord(kind: .f3BrakeCut, scooterId: "LAB", value: 1, day: 2, odoKm: 15, status: .fixed)],
                                     scooterId: "LAB", trackedSince: (1, 5))
        expect(MaintHistory.counts(h) == HistoryCounts(logged: 1, found: 1, dealtWith: 1, open: 0), "history counts")
        expect(ReportText.t(.historyTitle, .hebrew) != ReportText.t(.historyTitle, .english) && ReportLanguage.hebrew.rightToLeft,
               "English and Hebrew reports")
        expect.report("u202")
    }
}
