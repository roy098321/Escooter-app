import XCTest
@testable import CorckieCore

/// B81 (hotfix 103.081126.02): diary lines, the report window, the cause line, retention and the 5 MB drop order. Made-up data only.
final class MissedRideTests: XCTestCase {
    let now: Int64 = 1_794_000_000_000
    let min: Int64 = 60_000

    func test_diaryLine_roundTrip_andOneLine() {
        let l = DiaryLine(atMs: 123, kind: "bluetooth", text: "Connected\n· app\topen")
        XCTAssertEqual(DiaryLine.parse(l.encoded), DiaryLine(atMs: 123, kind: "bluetooth", text: "Connected · app open"))
        XCTAssertNil(DiaryLine.parse("garbage"))
    }

    func test_window() {
        XCTAssertEqual(MissedRideWhen.window(.justNow, nowMs: now, roughStartMs: nil), (now - 120 * min)...now)
        let start = now - 300 * min
        XCTAssertEqual(MissedRideWhen.window(.earlierToday, nowMs: now, roughStartMs: start), (start - 60 * min)...(start + 120 * min))
    }

    func test_retention_owner9Nov() {
        XCTAssertEqual(LogRetention.diaryDays, 30)
        XCTAssertEqual(LogRetention.errorLogDays, 30)
        XCTAssertEqual(LogRetention.messageLogDays, 90)
        XCTAssertEqual(LogRetention.reportDays, 30)
        XCTAssertEqual(LogRetention.cutoffMs(nowMs: now, days: 30), now - 30 * 86_400_000)
    }

    private func cause(_ lines: [DiaryLine], rides: [MissedRideRow] = [], always: Bool = true) -> String? {
        MissedRideGuess.cause(lines: lines, rides: rides, window: (now - 120 * min)...now, locationAlways: always, utcOffsetMin: 120)
    }

    func test_cause_eachKind() {
        let t = now - 30 * min
        XCTAssertTrue(cause([], rides: [MissedRideRow(startAt: t, kind: "ride", distanceM: 6_100)])?.contains("6.1 km") == true, "recorded after all")
        let dropped = cause([DiaryLine(atMs: t, kind: "ride", text: "B81: ride 3 dropped (noRiding), nothing saved")])
        XCTAssertTrue(dropped?.contains("no real riding was seen") == true, dropped ?? "nil")
        XCTAssertTrue(cause([], always: false)?.contains("While Using") == true)
        XCTAssertEqual(cause([]), "The app wasn't running then: iOS didn't wake it for the scooter.")
        XCTAssertEqual(cause([DiaryLine(atMs: t, kind: "app", text: "Foreground")]), "The app was running but never connected to the scooter.")
        XCTAssertEqual(cause([DiaryLine(atMs: t, kind: "bluetooth", text: "Connected · app in background")]), "The scooter connected, but no ride started.")
        XCTAssertNil(cause([DiaryLine(atMs: t, kind: "bluetooth", text: "Connected"), DiaryLine(atMs: t + min, kind: "ride", text: "B81: ride 4 started (wheel rolling)")]))
        XCTAssertEqual(cause([DiaryLine(atMs: now - 300 * min, kind: "app", text: "Foreground")]), "The app wasn't running then: iOS didn't wake it for the scooter.",
                       "lines outside the window don't count")
    }

    func test_cap_oldestFirst_rawBeforeSamples() {
        let files = [ExportCap.DetailFile(name: "new-s", atMs: 3, kind: .samples, bytes: 100),
                     ExportCap.DetailFile(name: "old-s", atMs: 1, kind: .samples, bytes: 100),
                     ExportCap.DetailFile(name: "old-r", atMs: 1, kind: .raw, bytes: 100),
                     ExportCap.DetailFile(name: "mid-r", atMs: 2, kind: .raw, bytes: 100)]
        XCTAssertEqual(ExportCap.dropOrder(files).map(\.name), ["old-r", "old-s", "mid-r", "new-s"])
        XCTAssertEqual(ExportCap.capBytes, 5 * 1_024 * 1_024)
        XCTAssertTrue(ExportCap.toDrop(files, zipBytes: 100, rawBytes: 400, cap: 200).isEmpty, "under the cap: nothing goes")
        // 1:1 zip, 50 over → 55 raw bytes with the margin → the oldest file only
        XCTAssertEqual(ExportCap.toDrop(files, zipBytes: 250, rawBytes: 250, cap: 200).map(\.name), ["old-r"])
        XCTAssertEqual(ExportCap.toDrop(files, zipBytes: 400, rawBytes: 400, cap: 200).map(\.name), ["old-r", "old-s", "mid-r"])
    }
}
