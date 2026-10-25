import XCTest
@testable import CorckieCore

/// B57: a ride the phone took over is never discarded with real GPS distance; distance and top speed from the GPS; kept as
/// "Recorded by phone"; the format-change log line; "Restore discarded ride" (last 30 days). All on made-up rides.
final class PhoneRideTests: XCTestCase {
    private func frame(_ t: Double, _ kmh: Double, amps: Double? = 8, batt: Int = 90, odo: Double = 100) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh
        f.currentA = amps
        f.batteryPct = batt
        f.odometerKm = odo
        f.voltage = 50
        return f
    }

    private func fix(_ t: Double, northM: Double, kmh: Double) -> PhoneFix {
        PhoneFix(t: t, lat: 10 + northM / 111_320, lon: -30, hAccM: 5, speedMps: kmh / 3.6)
    }

    /// The 24 Oct ride, made up: the ride starts, the format watch trips 2 s in, then 6 min at 20 km/h on GPS only (≈ 2 km),
    /// the odometer frozen at its first value; standing still at the end.
    func test_B57_formatChangedAtTheStart_rideKeptWithGpsDistance() {
        var e = RideEngine()
        e.handle(.connected, at: 0)
        e.handle(.frame(frame(0.5, 0)), at: 0.5)
        var north = 0.0
        var events: [RideEngineEvent] = []
        for t in stride(from: 1.0, through: 2, by: 0.5) {
            events += e.handle(.frame(frame(t, 15)), at: t)
            north += 15 / 3.6 / 2
            events += e.handle(.fix(fix(t, northM: north, kmh: 15)), at: t)
        }
        events += e.handle(.formatChanged, at: 2.2)
        for t in stride(from: 3.0, through: 363, by: 1) {
            north += 20 / 3.6
            events += e.handle(.frame(frame(t, 0, odo: 100)), at: t)       // untrusted readings: ignored
            events += e.handle(.fix(fix(t, northM: north, kmh: 20)), at: t)
        }
        XCTAssertNotNil(e.ride, "the ride started on GPS speed")
        for t in stride(from: 364.0, through: 460, by: 1) {
            events += e.handle(.fix(fix(t, northM: north, kmh: 0)), at: t)
        }
        let end = events.compactMap { if case .rideEnded(let x) = $0 { return x } else { return nil } }.first
        XCTAssertNotNil(end)
        XCTAssertTrue(end?.ride.gapList.contains { $0.reason == .formatChanged } ?? false)
        XCTAssertGreaterThan(end?.distanceM ?? 0, 1_500, "the GPS distance, not the frozen odometer")
        XCTAssertNotEqual(end?.sizeClass, .discarded)
    }

    func test_B57_rules() {
        XCTAssertEqual(PhoneRide.sizeClass(distanceM: 0, gpsM: 350, phoneTookOver: true), .shortHop, "≥ 300 m of GPS is kept")
        XCTAssertEqual(PhoneRide.sizeClass(distanceM: 0, gpsM: 250, phoneTookOver: true), .discarded)
        XCTAssertEqual(PhoneRide.sizeClass(distanceM: 0, gpsM: 900, phoneTookOver: false), .discarded, "without a takeover the usual M36 rule")
        XCTAssertEqual(PhoneRide.sizeClass(distanceM: 2_500, gpsM: 0, phoneTookOver: true), .ride)
        XCTAssertEqual(PhoneRide.distanceM(scooterM: 40, gpsM: 1_930, scooterLost: true), 1_930)
        XCTAssertEqual(PhoneRide.distanceM(scooterM: 4_000, gpsM: 4_300, scooterLost: false), 4_000, "a short blip keeps the odometer")
        XCTAssertEqual(PhoneRide.topSpeedKmh(scooterKmh: 0, gpsKmh: 27, scooterLost: true), 27)
        XCTAssertEqual(PhoneRide.topSpeedKmh(scooterKmh: 31, gpsKmh: 40, scooterLost: false), 31)
        XCTAssertTrue(PhoneRide.recordedByPhone(formatChanged: true, scooterGapS: 0, totalS: 360))
        XCTAssertTrue(PhoneRide.recordedByPhone(formatChanged: false, scooterGapS: 200, totalS: 360))
        XCTAssertFalse(PhoneRide.recordedByPhone(formatChanged: false, scooterGapS: 20, totalS: 360))
    }

    func test_B57_restore_last30DaysOnly_neverDiscardedAgain() {
        let now: Int64 = 1_790_000_000_000
        let day: Int64 = 86_400_000
        let rows: [(id: String, startAt: Int64, kind: String, isSimulated: Bool, ended: Bool)] = [
            ("old", now - 31 * day, "discarded", false, true),
            ("a", now - 2 * day, "discarded", false, true),
            ("b", now - day, "discarded", false, true),
            ("sim", now - day, "discarded", true, true),
            ("open", now - day, "discarded", false, false),
            ("ride", now - day, "ride", false, true)
        ]
        XCTAssertEqual(PhoneRide.restoreCandidates(rows, nowMs: now), ["b", "a"])
        XCTAssertEqual(PhoneRide.restoredKind(distanceM: 0, gpsM: 1_930), .shortHop)
        XCTAssertEqual(PhoneRide.restoredKind(distanceM: 120, gpsM: 0), .shortHop, "the rider asked to keep it")
        XCTAssertEqual(PhoneRide.restoredKind(distanceM: 0, gpsM: 6_000), .ride)
    }

    func test_B57_formatChangeLine_hasReasonDroppedFieldsAndPacket() {
        let line = PhoneRide.formatChangeLine(reason: "64% of frames failed the checks in the last minute", dropped: ["speed", "odometer"],
                                              packet: [0x19, 0x30, 0x00, 0x66])
        XCTAssertEqual(line, "Phone took over (formatChanged): 64% of frames failed the checks in the last minute \u{00B7} last frame dropped: speed, odometer \u{00B7} packet 19 30 00 66")
    }

    func test_B57_extrasJSON_andSummary() {
        var x = RideExtras()
        x.recordedByPhone = true
        x.formatReason = "No valid packet A for 10 s"
        let back = RideExtras.parse(x.json)
        XCTAssertEqual(back, x)
        XCTAssertEqual(RideExtras.parse("{}"), RideExtras(), "missing fields are fine")
        var input = RideDetailInput(startAt: 1_790_000_000_000, kind: "shortHop", distanceM: 1_930, totalS: 360)
        input.recordedByPhone = true
        input.formatReason = x.formatReason
        let m = RideSummaryBuilder.build(input, gaps: [RideGapSpan(kind: "scooter", startT: 2_000, endT: nil)], points: [])
        XCTAssertEqual(m.subtitle, "Short hop \u{00B7} Recorded by phone")
        XCTAssertTrue(m.notes.contains { $0.kind == .phone && $0.text.hasPrefix("Recorded by phone") })
        XCTAssertTrue(m.infoLines.contains("Phone took over: No valid packet A for 10 s"))
    }

    func test_B57_gpsTopSpeedAndDistance_fromSamples() {
        var samples: [RideSample] = []
        for i in 0..<20 {
            let t = Double(i) * 5
            samples.append(RideSample(t: t, gpsSpeedKmh: 25, lat: 10 + Double(i) * 35 / 111_320, lon: -30, hAccM: 5))
        }
        let m = RideMetricsCalculator.compute(samples)
        XCTAssertEqual(m.gpsTopSpeedKmh, 25, accuracy: 0.01)
        XCTAssertGreaterThan(m.gpsDistanceM, 600)
        XCTAssertEqual(m.topSpeedKmh, 0, "no scooter speed")
    }
}
