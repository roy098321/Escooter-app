import CorckieCore
import Foundation

/// Hotfix 103.081126.02 check u200 (B81), on made-up input; one harmless "lab check" line goes into the real diary to prove it is written.
@MainActor
enum H0102Checks {
    typealias Expect = B101LateChecks.Expect

    static func run() {
        let expect = Expect()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let marker = "lab check u200 \(now)"
        Diary.shared.note("report", marker)
        expect(Diary.shared.lines(in: (now - 60_000)...(now + 60_000)).contains { $0.text == marker }, "the diary is written to a file and read back")
        let w = (now - 7_200_000)...now
        expect(MissedRideGuess.cause(lines: [], rides: [], window: w, locationAlways: true, utcOffsetMin: 0)
               == "The app wasn't running then: iOS didn't wake it for the scooter.", "no diary in the window: iOS didn't wake the app")
        expect(MissedRideGuess.cause(lines: [DiaryLine(atMs: now - 60_000, kind: "ride", text: "B81: ride 2 dropped (gpsStill), nothing saved")],
                                     rides: [], window: w, locationAlways: true, utcOffsetMin: 0)?.contains("GPS stayed still") == true,
               "a dropped ride names its reason")
        let files = [ExportCap.DetailFile(name: "b", atMs: 2, kind: .raw, bytes: 1), ExportCap.DetailFile(name: "a", atMs: 1, kind: .samples, bytes: 1),
                     ExportCap.DetailFile(name: "a-raw", atMs: 1, kind: .raw, bytes: 1)]
        expect(ExportCap.dropOrder(files).map(\.name) == ["a-raw", "a", "b"], "over 5 MB: oldest first, raw packets before samples")
        expect(LogRetention.diaryDays == 30 && LogRetention.messageLogDays == 90, "diary 30 days, messages 90 days")
        expect.report("u200")
    }
}
