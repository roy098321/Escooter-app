import XCTest
@testable import CorckieCore

/// M1-16: backup timing, names, pruning, texts, phone battery use, gzip frame.
final class BackupPlanTests: XCTestCase {
    private func ms(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    func testFullDueNeverOrAfterSevenDays() {
        let now = ms("2026-10-10T12:00:00Z")
        XCTAssertTrue(BackupPlan.fullDue(lastFullMs: nil, nowMs: now))
        XCTAssertFalse(BackupPlan.fullDue(lastFullMs: ms("2026-10-04T12:00:01Z"), nowMs: now))
        XCTAssertTrue(BackupPlan.fullDue(lastFullMs: ms("2026-10-03T12:00:00Z"), nowMs: now))
    }

    func testBannerAfterFourteenDaysOnlyWithRides() {
        let now = ms("2026-10-20T12:00:00Z")
        XCTAssertFalse(BackupPlan.bannerShown(lastBackupMs: nil, oldestRideMs: nil, nowMs: now))
        XCTAssertFalse(BackupPlan.bannerShown(lastBackupMs: ms("2026-10-10T12:00:00Z"), oldestRideMs: 1, nowMs: now))
        XCTAssertTrue(BackupPlan.bannerShown(lastBackupMs: ms("2026-10-06T12:00:00Z"), oldestRideMs: 1, nowMs: now))
        XCTAssertTrue(BackupPlan.bannerShown(lastBackupMs: nil, oldestRideMs: ms("2026-10-05T12:00:00Z"), nowMs: now))
        XCTAssertFalse(BackupPlan.bannerShown(lastBackupMs: nil, oldestRideMs: ms("2026-10-15T12:00:00Z"), nowMs: now))
    }

    func testLastBackupText() {
        let now = ms("2026-10-05T20:00:00Z")
        XCTAssertEqual(BackupPlan.lastBackupText(lastMs: nil, nowMs: now, utcOffsetMin: 0), "never")
        XCTAssertEqual(BackupPlan.lastBackupText(lastMs: ms("2026-10-05T18:10:00Z"), nowMs: now, utcOffsetMin: 0), "today 18:10")
        XCTAssertEqual(BackupPlan.lastBackupText(lastMs: ms("2026-10-04T18:10:00Z"), nowMs: now, utcOffsetMin: 0), "yesterday 18:10")
        XCTAssertEqual(BackupPlan.lastBackupText(lastMs: ms("2026-10-01T18:10:00Z"), nowMs: now, utcOffsetMin: 0), "1 Oct, 18:10")
    }

    func testNames() {
        XCTAssertEqual(BackupPlan.fullName(atMs: ms("2026-10-04T09:00:00Z"), utcOffsetMin: 0), "full-2026-10-04.corckie")
        XCTAssertEqual(BackupPlan.rideName(startAtMs: ms("2026-10-05T08:17:00Z"), utcOffsetMin: 0, rideId: "abc"),
                       "2026-10-05_0817_abc.ride")
        XCTAssertEqual(BackupPlan.fullDate("full-2026-10-04.corckie"), "2026-10-04")
        XCTAssertNil(BackupPlan.fullDate("latest.json"))
    }

    func testPruningKeepsThreeFullsAndDropsOlderDeltas() {
        let fulls = ["full-2026-09-20.corckie", "full-2026-10-04.corckie", "full-2026-09-13.corckie",
                     "full-2026-09-27.corckie", "latest.json"]
        XCTAssertEqual(BackupPlan.fullsToDelete(fulls), ["full-2026-09-13.corckie"])
        let rides = ["2026-10-03_0800_a.ride", "2026-10-04_0900_b.ride", "2026-10-05_0817_c.ride", "notes.txt"]
        XCTAssertEqual(BackupPlan.ridesToDelete(rides, newestFullDate: "2026-10-04"), ["2026-10-03_0800_a.ride"])
        XCTAssertEqual(BackupPlan.ridesToDelete(rides, newestFullDate: nil), [])
    }

    func testPhoneBatteryUse() throws {
        XCTAssertEqual(try XCTUnwrap(PhoneBatteryUse.per30Min(startPct: 80, endPct: 74, rideS: 1800)), 6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(PhoneBatteryUse.per30Min(startPct: 80, endPct: 70, rideS: 3600)), 5, accuracy: 0.001)
        XCTAssertNil(PhoneBatteryUse.per30Min(startPct: 80, endPct: 79, rideS: 600))
        XCTAssertNil(PhoneBatteryUse.per30Min(startPct: nil, endPct: 79, rideS: 3000))
        XCTAssertTrue(PhoneBatteryUse.withinLimit(10))
        XCTAssertFalse(PhoneBatteryUse.withinLimit(10.5))
    }

    func testGzipFrameCrcAndLayout() {
        XCTAssertEqual(GzipFrame.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        let original = Array("hello".utf8)
        let out = GzipFrame.wrap(deflated: [1, 2, 3], original: original)
        XCTAssertEqual(Array(out.prefix(3)), [0x1F, 0x8B, 0x08])
        XCTAssertEqual(out.count, 10 + 3 + 8)
        XCTAssertEqual(Array(out.suffix(4)), [5, 0, 0, 0])
    }
}
