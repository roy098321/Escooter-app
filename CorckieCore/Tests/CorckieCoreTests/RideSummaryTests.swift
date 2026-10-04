import XCTest
@testable import CorckieCore

/// M1-13: the ride summary / detail numbers and notes, from golden-ride-sized values (ride 1: 437 Wh, 16.3 km).
final class RideSummaryTests: XCTestCase {
    private func ms(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private func golden() -> RideDetailInput {
        RideDetailInput(startAt: ms("2026-10-07T18:02:00Z"), utcOffsetMin: 0, kind: "ride", status: "ended",
                        endReason: "held", distanceM: 16_300, totalS: 2_345, movingS: 2_100, avgMovingMps: 7.76,
                        topSpeedMps: 11.4, stops: 3, energyWhRaw: 437.2, usedPct: 24, startRestPct: 88, endRestPct: 64,
                        odoStartKm: 120.4, odoEndKm: 136.7, elevGainM: 45.4, elevLossM: 40.2, tempPeakC: 52.6,
                        tempRiseC: 14.2, hasGps: true)
    }

    private func points() -> [RidePoint] {
        var out: [RidePoint] = []
        for i in 0..<20 {
            let step: Double = Double(i) * 0.0003
            let lat: Double = 40.0 + step
            let lon: Double = -75.0 + step
            let kmh: Double = Double(i) * 2
            let pct: Int = 88 - i / 5
            out.append(RidePoint(t: Int64(i) * 5000, lat: lat, lon: lon, hAccM: 5, speedKmh: kmh, batteryPct: pct, mode: "scooter"))
        }
        return out
    }

    private func stat(_ list: [SummaryStat], _ label: String) -> String? { list.first { $0.label == label }?.value }

    func testGoldenRideNumbers() {
        let m = RideSummaryBuilder.build(golden(), gaps: [], points: points())
        XCTAssertEqual(m.title, "Wed 7 Oct, 18:02")
        XCTAssertEqual(stat(m.mainStats, "Time"), "39 min")
        XCTAssertEqual(stat(m.mainStats, "Moving time"), "35 min")
        XCTAssertEqual(stat(m.mainStats, "Distance"), "16.3 km")
        XCTAssertEqual(stat(m.mainStats, "Avg. speed"), "28 km/h")
        XCTAssertEqual(stat(m.mainStats, "Battery"), "88% \u{2192} 64%")
        XCTAssertEqual(stat(m.mainStats, "Battery per km"), "~1.5 %/km")
        XCTAssertEqual(stat(m.scooterStats, "Top speed"), "41 km/h")
        XCTAssertEqual(stat(m.scooterStats, "Energy"), "~437 Wh")
        XCTAssertEqual(stat(m.scooterStats, "Stops"), "3")
        XCTAssertEqual(stat(m.scooterStats, "Elevation"), "~+45 m / \u{2212}40 m")
        XCTAssertEqual(stat(m.scooterStats, "Temperature"), "peak 53 \u{00B0}C (+14)")
        XCTAssertFalse(m.noGps)
        XCTAssertTrue(m.notes.isEmpty)
        XCTAssertEqual(m.infoLines, ["Odometer 120.4 km to 136.7 km", "Ended by you (held the stop button)"])
    }

    func testDurationAndDistanceFormats() {
        XCTAssertEqual(RideSummaryBuilder.duration(45), "45 s")
        XCTAssertEqual(RideSummaryBuilder.duration(34 * 60), "34 min")
        XCTAssertEqual(RideSummaryBuilder.duration(3_900), "1 h 05 min")
        XCTAssertEqual(RideSummaryBuilder.distance(850), "0.85 km")
        XCTAssertEqual(RideSummaryBuilder.distance(12_345), "12.3 km")
    }

    func testBatteryPerKmNeedsOneKm_andBatteryFallsBackToSamples() {
        var r = golden()
        r.distanceM = 800
        r.startRestPct = nil
        r.endRestPct = nil
        let m = RideSummaryBuilder.build(r, gaps: [], points: points())
        XCTAssertEqual(stat(m.mainStats, "Battery per km"), "\u{2013}")
        XCTAssertEqual(stat(m.mainStats, "Battery"), "88% \u{2192} 85%")
    }

    func testUnknownNumbersAreDashesNeverZeros() {
        let m = RideSummaryBuilder.build(RideDetailInput(startAt: 0), gaps: [], points: [])
        XCTAssertTrue(m.mainStats.allSatisfy { $0.value == "\u{2013}" })
        XCTAssertEqual(stat(m.scooterStats, "Elevation"), "\u{2013}")
        XCTAssertEqual(stat(m.scooterStats, "Temperature"), "\u{2013}")
        XCTAssertTrue(m.noGps)
    }

    func testNoGpsRide_S7() {
        var r = golden()
        r.hasGps = false
        let m = RideSummaryBuilder.build(r, gaps: [], points: [RidePoint(t: 0, speedKmh: 20, batteryPct: 80)])
        XCTAssertTrue(m.noGps)
        XCTAssertTrue(m.path.isEmpty)
        XCTAssertEqual(stat(m.mainStats, "Distance"), "16.3 km")
    }

    func testPhoneStretchIsDashed_andWalkIsMarkedAndKeptOutOfTheSpeedRuns() {
        var pts = points()
        for i in 10..<14 { pts[i].mode = "phone" }
        for i in 14..<18 { pts[i].mode = "walk" }
        let m = RideSummaryBuilder.build(golden(), gaps: [], points: pts)
        XCTAssertTrue(m.path.segments.contains { $0.dashed })
        XCTAssertTrue(m.path.segments.contains { !$0.dashed })
        XCTAssertEqual(m.path.walks.count, 1)
        XCTAssertGreaterThanOrEqual(m.path.walks[0].count, 4)
        XCTAssertTrue(m.notes.contains { $0.kind == .walk })
    }

    func testGapsRecoveredHeatAndIgnoredNotes() {
        var r = golden()
        r.status = "recovered"
        r.tempPeakC = 93
        r.ignoredReadings = 2
        let gaps = [RideGapSpan(kind: "scooter", startT: 60_000, endT: 190_000),
                    RideGapSpan(kind: "gps", startT: 300_000, endT: 312_000)]
        let m = RideSummaryBuilder.build(r, gaps: gaps, points: points())
        let kinds = m.notes.map(\.kind)
        XCTAssertEqual(kinds, [.recovered, .phone, .gap, .heat, .ignored])
        XCTAssertTrue(m.notes[1].text.contains("2 min"))
        XCTAssertTrue(m.notes[2].text.contains("12 s"))
        XCTAssertTrue(m.notes[3].text.contains("hot"))
        r.tempPeakC = 101
        XCTAssertTrue(RideSummaryBuilder.build(r, gaps: [], points: []).notes.contains { $0.text.contains("very hot") })
    }

    func testOpenGapRunsToTheEndOfTheRide() {
        XCTAssertEqual(RideSummaryBuilder.gapSeconds([RideGapSpan(kind: "scooter", startT: 2_000_000, endT: nil)],
                                                     kind: "scooter", totalS: 2_345), 345, accuracy: 0.001)
    }

    func testNoRecordsOrComparisonsInTheText_P3() {
        var r = golden()
        r.status = "recovered"
        r.tempPeakC = 95
        let m = RideSummaryBuilder.build(r, gaps: [RideGapSpan(kind: "scooter", startT: 0, endT: 5000)], points: points())
        var text = ""
        for s in m.mainStats + m.scooterStats { text += s.label + s.value }
        for n in m.notes { text += n.text }
        for word in ["record", "best", "personal", "badge", "faster than", "your usual", "streak"] {
            XCTAssertFalse(text.lowercased().contains(word), word)
        }
    }

    func testTitleUsesTheRidesOwnOffset() {
        XCTAssertEqual(RideSummaryBuilder.title(startAt: ms("2026-10-07T22:30:00Z"), utcOffsetMin: 180), "Thu 8 Oct, 01:30")
    }

    func testBoundsGetRoomAndMinimumSpan() {
        let path = RidePathBuilder.build(points())
        let b = try? XCTUnwrap(path.bounds)
        XCTAssertNotNil(b)
        XCTAssertGreaterThan(b?.latSpan ?? 0, 0.0057 * 1.3)
        let one = RidePathBuilder.build([RidePoint(t: 0, lat: 1, lon: 1, hAccM: 5)])
        XCTAssertEqual(one.bounds?.latSpan, 0.002)
    }

    func testPoorFixesAreLeftOutOfThePath() {
        let pts = [RidePoint(t: 0, lat: 1, lon: 1, hAccM: 5, speedKmh: 10),
                   RidePoint(t: 5000, lat: 9, lon: 9, hAccM: 80, speedKmh: 10),
                   RidePoint(t: 10000, lat: 1.001, lon: 1.001, hAccM: 5, speedKmh: 10)]
        let path = RidePathBuilder.build(pts)
        XCTAssertEqual(path.segments.flatMap(\.coords).count, 2)
    }
}
