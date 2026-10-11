import XCTest
@testable import CorckieCore

/// M5-05 / M5-07: restore by ride, the words after a restore, raw data retention, CSV and GPX of a ride.
final class ExportRestoreTests: XCTestCase {
    // MARK: Restore plan

    func testNewRidesAreAddedKnownOnesSkipped() {
        let existing = [RestoreRide(id: "a", startAt: 1_000_000, distanceM: 5_000)]
        let incoming = [RestoreRide(id: "a", startAt: 1_000_000, distanceM: 5_000),      // same id
                        RestoreRide(id: "b", startAt: 9_000_000, distanceM: 7_000),      // new
                        RestoreRide(id: "c", startAt: 1_001_500, distanceM: 5_040)]      // other id, same ride (1.5 s, 0.8%)
        let plan = RestorePlan.decide(existing: existing, incoming: incoming)
        XCTAssertEqual(plan.add, ["b"])
        XCTAssertEqual(plan.skip, ["a", "c"])
    }

    func testSameStartDifferentDistanceIsAnotherRide() {
        let existing = [RestoreRide(id: "a", startAt: 1_000_000, distanceM: 5_000)]
        let plan = RestorePlan.decide(existing: existing, incoming: [RestoreRide(id: "x", startAt: 1_000_500, distanceM: 6_000)])
        XCTAssertEqual(plan.add, ["x"])
        // 3 s apart is not the same start
        let late = RestorePlan.decide(existing: existing, incoming: [RestoreRide(id: "y", startAt: 1_003_100, distanceM: 5_000)])
        XCTAssertEqual(late.add, ["y"])
    }

    func testRepeatsInsideTheFileAreAddedOnce() {
        let r = RestoreRide(id: "n", startAt: 5_000_000, distanceM: 3_000)
        let plan = RestorePlan.decide(existing: [], incoming: [r, r, RestoreRide(id: "n2", startAt: 5_000_300, distanceM: 3_010)])
        XCTAssertEqual(plan.add, ["n"])
        XCTAssertEqual(plan.skip, ["n", "n2"])
    }

    func testRestoringTwiceAddsNothing() {
        let file = [RestoreRide(id: "a", startAt: 1_000, distanceM: 1_000), RestoreRide(id: "b", startAt: 90_000_000, distanceM: 2_000)]
        let first = RestorePlan.decide(existing: [], incoming: file)
        XCTAssertEqual(first.add.count, 2)
        let second = RestorePlan.decide(existing: file, incoming: file)
        XCTAssertTrue(second.add.isEmpty)
        XCTAssertEqual(second.skip.count, 2)
    }

    func testUnknownDistanceStillMatchesOnStart() {
        let existing = [RestoreRide(id: "a", startAt: 1_000_000, distanceM: nil)]
        XCTAssertEqual(RestorePlan.decide(existing: existing, incoming: [RestoreRide(id: "z", startAt: 1_000_900, distanceM: 4_000)]).skip, ["z"])
    }

    func testReportText() {
        var r = RestoreReport()
        XCTAssertEqual(r.text, "0 rides added.")
        r.ridesAdded = 1
        XCTAssertEqual(r.text, "1 ride added.")
        r.ridesAdded = 12
        r.ridesSkipped = 3
        r.ridesFailed = 1
        r.otherRows = 20
        XCTAssertEqual(r.text, "12 rides added, 3 already on this phone, 1 could not be read, 20 places, routes and settings added.")
    }

    // MARK: Retention

    func testRetentionSettingStorage() {
        XCTAssertEqual(RawRetention.default, .days90)
        XCTAssertEqual(RawRetention(stored: nil), .days90)
        XCTAssertEqual(RawRetention(stored: "garbage"), .days90)
        for r in RawRetention.allCases { XCTAssertEqual(RawRetention(stored: r.storageValue), r) }
        XCTAssertEqual(RawRetention.allCases.map(\.rawValue), ["90 days", "1 year", "Forever"])
    }

    func testRetentionCutoffsAndWhatIsDeleted() {
        let now: Int64 = 1_800_000_000_000
        let day: Int64 = 86_400_000
        XCTAssertEqual(RawRetention.days90.cutoffMs(nowMs: now), now - 90 * day)
        XCTAssertEqual(RawRetention.year.cutoffMs(nowMs: now), now - 365 * day)
        XCTAssertNil(RawRetention.forever.cutoffMs(nowMs: now))
        // raw scooter packets older than 90 days go, newer ones stay
        XCTAssertTrue(RawRetention.days90.deletes(kind: "scooter", endAtMs: now - 91 * day, nowMs: now))
        XCTAssertFalse(RawRetention.days90.deletes(kind: "scooter", endAtMs: now - 89 * day, nowMs: now))
        XCTAssertTrue(RawRetention.days90.deletes(kind: "phone", endAtMs: now - 200 * day, nowMs: now))
        // the energy channel is kept forever (A1)
        XCTAssertFalse(RawRetention.days90.deletes(kind: "energy", endAtMs: now - 900 * day, nowMs: now))
        // one year keeps what 90 days would delete; forever deletes nothing
        XCTAssertFalse(RawRetention.year.deletes(kind: "scooter", endAtMs: now - 200 * day, nowMs: now))
        XCTAssertFalse(RawRetention.forever.deletes(kind: "scooter", endAtMs: now - 5_000 * day, nowMs: now))
    }

    // MARK: CSV and GPX

    func testIsoTimeWithOffset() {
        XCTAssertEqual(RideExport.iso(ms: 1_790_000_000_000, utcOffsetMin: 180), "2026-09-21T17:13:20+03:00")
        XCTAssertEqual(RideExport.iso(ms: 1_790_000_000_000, utcOffsetMin: -300), "2026-09-21T09:13:20-05:00")
        XCTAssertEqual(RideExport.iso(ms: 0, utcOffsetMin: 0), "1970-01-01T00:00:00+00:00")
        XCTAssertEqual(RideExport.iso(ms: 1_000, utcOffsetMin: 330), "1970-01-01T05:30:01+05:30")
        // across midnight: 23:30 UTC at +03:00 is 02:30 the next day
        XCTAssertEqual(RideExport.iso(ms: 1_790_033_400_000, utcOffsetMin: 180), "2026-09-22T02:30:00+03:00")
    }

    private func rows() -> [ReplayRow] {
        [ReplayRow(t: 0, lat: 10.0, lon: -30.0, hAccM: 5, speedKmh: 18, gpsKmh: 17.5, altM: 30, powerW: 216, batteryPct: 80, tempC: 30),
         ReplayRow(t: 5, lat: 10.0002, lon: -30.0, hAccM: 5, speedKmh: 19.5, gpsKmh: nil, altM: 30.5, powerW: 230, batteryPct: 80, tempC: 30.5),
         ReplayRow(t: 10, lat: nil, lon: nil, hAccM: nil, speedKmh: 0, gpsKmh: nil, altM: nil, powerW: 0, batteryPct: 79, tempC: nil)]
    }

    func testCsvHasAHeaderAndOneLinePerReading() {
        let csv = RideExport.csv(rows: rows(), startAtMs: 1_790_000_000_000, utcOffsetMin: 180)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], RideExport.csvHeader)
        XCTAssertEqual(lines[1], "2026-09-21T17:13:20+03:00,0.0,18.0,17.5,10.000000,-30.000000,30.0,216,80,30.0")
        XCTAssertEqual(lines[2], "2026-09-21T17:13:25+03:00,5.0,19.5,,10.000200,-30.000000,30.5,230,80,30.5")
        XCTAssertEqual(lines[3], "2026-09-21T17:13:30+03:00,10.0,0.0,,,,,0,79,")
    }

    func testGpxHasTrackPointsWithTimeElevationAndScooterExtras() {
        let gpx = RideExport.gpx(name: "Morning <ride> & co", rows: rows(), startAtMs: 1_790_000_000_000, utcOffsetMin: 180)
        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(gpx.contains("<name>Morning &lt;ride&gt; &amp; co</name>"))
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt ").count - 1, 2)                       // the third reading has no position
        XCTAssertTrue(gpx.contains("<trkpt lat=\"10.000000\" lon=\"-30.000000\"><ele>30.0</ele><time>2026-09-21T17:13:20+03:00</time>"))
        XCTAssertTrue(gpx.contains("<speed>5.00</speed><power>216</power>"))                      // 18 km/h = 5 m/s
        XCTAssertTrue(gpx.hasSuffix("</trkseg></trk>\n</gpx>\n"))
    }
}
