import CorckieCore
import XCTest

/// Batch 10 guard tests (maintenance: fault recognition, maintenance screen, access, B97–B99). Logic in CorckieCore, plus checks on
/// the app's source text (Linux CI cannot build the app, like ThemeGuardTests).
final class Batch110Tests: XCTestCase {
    private let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func text(_ path: String) throws -> String {
        try String(contentsOf: appFolder.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: N10-16 · B97 Home logo

    /// The Home header is the C mark only: no name next to it (iOS 26 clipped it to a sliver); the name stays for VoiceOver
    func test_B97_homeHeaderIsTheMarkOnly() throws {
        let home = try text("UI/Home/HomeView.swift")
        XCTAssertTrue(home.contains("Image(\"HeaderMark\")"))
        XCTAssertFalse(home.contains("Text(\"CorckieApp\")"), "no visible name in the header")
        XCTAssertTrue(home.contains(".accessibilityLabel(\"CorckieApp\")"))
        let asset = appFolder.appendingPathComponent("Resources/Assets.xcassets/HeaderMark.imageset/HeaderMark@3x.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path))
    }

    // MARK: N10-17 · B98 grey rows

    /// Rows inside a List never get the N7-13 scroll fade (there the phase never reaches identity, so every row sat at 0.55)
    func test_B98_noScrollFadeOnListRows() throws {
        for path in ["UI/Rides/RidesListView.swift", "UI/Routes/RoutesListView.swift", "UI/Routes/PlacesView.swift"] {
            XCTAssertFalse(try text(path).contains(".scrollReactive()"), path)
        }
    }

    // MARK: N10-18 · B99 colour strip

    /// The ride's colour strip is a rounded bar set in from the row edge, so the zoom clip can't shave it into a crescent
    func test_B99_colourStripIsABar() throws {
        let rides = try text("UI/Rides/RidesListView.swift")
        guard let start = rides.range(of: "private func placeStrip") else { return XCTFail("placeStrip missing") }
        let body = String(rides[start.lowerBound...].prefix(900))
        XCTAssertFalse(body.contains("Capsule()"), "a capsule is cut into a crescent by the rounded clip")
        XCTAssertTrue(body.contains("RoundedRectangle(cornerRadius: 2"))
        XCTAssertTrue(body.contains(".padding(.leading, 4)"), "set in from the zoom clip's corner")
    }
    // MARK: Shared gate (HARSH RULE)

    private func learned(_ kind: FaultKind, _ values: [Double] = [10, 11, 9, 10, 12, 10, 11, 10, 9, 10]) -> FaultBaseline {
        var b = FaultBaseline()
        for v in values { b = FaultGate.evaluate(b, kind: kind, value: v, day: 100).1 }
        return b
    }

    func test_gate_newRiderIsSilentForTenRides() {
        var b = FaultBaseline()
        for i in 0..<10 {
            let (v, nb) = FaultGate.evaluate(b, kind: .f1Sag, value: i == 9 ? 99 : 10, day: 100)
            XCTAssertEqual(v, .learning, "ride \(i + 1)")
            b = nb
        }
        XCTAssertTrue(b.learned)
    }

    func test_gate_needsWorstNormalPlusTenPercent_andThreeInARow() {
        var b = learned(.f1Sag)                      // worst normal 12 → bar 13.2
        XCTAssertEqual(FaultGate.bar(b, kind: .f1Sag)!, 13.2, accuracy: 1e-9)
        var v: FaultVerdict
        (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: 13.1, day: 101); XCTAssertEqual(v, .normal, "inside the margin")
        (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: 15, day: 102); XCTAssertEqual(v, .watching)
        (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: 15, day: 103); XCTAssertEqual(v, .watching)
        (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: 15, day: 104); XCTAssertEqual(v, .alert(value: 15))
        XCTAssertFalse(b.samples.contains(15), "a fault value is never learned as normal")
    }

    func test_gate_aNormalRideBreaksTheRun() {
        var b = learned(.f6Heat)
        b = FaultGate.evaluate(b, kind: .f6Heat, value: 30, day: 101).1
        b = FaultGate.evaluate(b, kind: .f6Heat, value: 30, day: 102).1
        b = FaultGate.evaluate(b, kind: .f6Heat, value: 10, day: 103).1
        XCTAssertEqual(FaultGate.evaluate(b, kind: .f6Heat, value: 30, day: 104).0, .watching)
    }

    func test_gate_ruledOutRideTeachesAndSaysNothing() {
        let b = learned(.f1Sag)
        let (v, nb) = FaultGate.evaluate(b, kind: .f1Sag, value: 99, ruledOut: true, day: 101)
        XCTAssertEqual(v, .ruledOut)
        XCTAssertEqual(nb, b)
    }

    func test_gate_minGapStopsAHairTrigger() {
        let b = learned(.f5Tyre, Array(repeating: 1.0, count: 10))
        XCTAssertEqual(FaultGate.bar(b, kind: .f5Tyre, minGap: 3)!, 4.0, accuracy: 1e-9)
    }

    func test_gate_lowerIsWorseForFullVoltage() {
        var b = learned(.f12FullVoltage, [54.4, 54.0, 53.4, 54.2, 54.1, 53.9, 54.3, 54.0, 53.8, 54.4])
        let bar = FaultGate.bar(b, kind: .f12FullVoltage, minGap: 0.5)!
        XCTAssertEqual(bar, 53.4 - 0.55, accuracy: 1e-9, "0.5 V below the lowest normal full voltage, + 10 %")
        var v: FaultVerdict = .normal
        for d in 0..<3 { (v, b) = FaultGate.evaluate(b, kind: .f12FullVoltage, value: 52.7, minGap: 0.5, day: 101 + d) }
        XCTAssertEqual(v, .alert(value: 52.7))
    }

    func test_gate_notAgainForTwoWeeksUnlessWorse() {
        var b = learned(.f1Sag)
        var v: FaultVerdict = .normal
        for d in 0..<3 { (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: 15, day: 101 + d) }
        XCTAssertEqual(v, .alert(value: 15))
        (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: 15, day: 110); XCTAssertEqual(v, .watching, "same finding inside 2 weeks")
        (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: 17, day: 111); XCTAssertEqual(v, .alert(value: 17), "worse")
        (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: 17, day: 125); XCTAssertEqual(v, .alert(value: 17), "2 weeks later")
    }

    func test_gate_checkedFineRaisesTheBar_twiceIsQuiet() {
        var b = learned(.f1Sag)
        for d in 0..<3 { b = FaultGate.evaluate(b, kind: .f1Sag, value: 15, day: 101 + d).1 }
        b = FaultGate.checkedFine(b, kind: .f1Sag)
        XCTAssertEqual(FaultGate.bar(b, kind: .f1Sag)!, 16.5, accuracy: 1e-9)
        XCTAssertEqual(FaultGate.evaluate(b, kind: .f1Sag, value: 16, day: 130).0, .normal)
        b = FaultGate.checkedFine(b, kind: .f1Sag)
        XCTAssertEqual(FaultGate.evaluate(b, kind: .f1Sag, value: 99, day: 140).0, .quiet)
    }

    func test_gate_powerCutAndBrakeTellOnTheFirstRideAfterLearning() {
        var b = learned(.f2PowerCut, Array(repeating: 0, count: 10))
        let (v, nb) = FaultGate.evaluate(b, kind: .f2PowerCut, value: 1, day: 101)
        XCTAssertEqual(v, .alert(value: 1))
        b = nb
        XCTAssertEqual(FaultKind.f2PowerCut.level, .red)
        XCTAssertEqual(FaultKind.f3BrakeCut.level, .red)
        XCTAssertEqual(FaultKind.f16OdoReset.level, .info)
    }

    func test_gate_odometerResetIsAFactNotAPattern() {
        XCTAssertEqual(FaultGate.evaluate(FaultBaseline(), kind: .f16OdoReset, value: 1, day: 5).0, .alert(value: 1))
    }

    func test_onlyOneFaultPerSummary_redFirst() {
        let pick = FaultFinding.pickOne([FaultFinding(kind: .f1Sag, value: 1, excess: 9),
                                         FaultFinding(kind: .f3BrakeCut, value: 1, excess: 0.1),
                                         FaultFinding(kind: .f16OdoReset, value: 1, excess: 50)])
        XCTAssertEqual(pick?.kind, .f3BrakeCut)
        XCTAssertNil(FaultFinding.pickOne([]))
    }

    func test_book_perScooter_firmwareRelearns_partReplacedResets() {
        var book = FaultBook()
        book.set(learned(.f1Sag), "A", .f1Sag)
        book.set(learned(.f5Tyre), "A", .f5Tyre)
        XCTAssertFalse(book.baseline("B", .f1Sag).learned, "normals are per scooter")
        XCTAssertFalse(book.noteFirmware("1.0", scooterId: "A"), "first sighting is not a change")
        book.partReplaced(.tyres, scooterId: "A")
        XCTAssertFalse(book.baseline("A", .f5Tyre).learned)
        XCTAssertTrue(book.baseline("A", .f1Sag).learned)
        XCTAssertTrue(book.noteFirmware("1.1", scooterId: "A"))
        XCTAssertFalse(book.baseline("A", .f1Sag).learned, "firmware change → relearn")
    }

    func test_dayNumberHasNoTimeOfDay() {
        XCTAssertEqual(FaultGate.day(epochMs: 86_400_000 * 3 + 1), 3)
        XCTAssertEqual(FaultGate.day(epochMs: 86_400_000 * 4 - 1), 3)
    }
    // MARK: Detectors (synthetic rides: a healthy one stays quiet, a faulty one is caught)

    private func frame(_ t: Double, kmh: Double? = 20, v: Double? = 50, a: Double? = 5, temp: Double? = 40, brake: Bool = false,
                       off: Bool = false, odo: Double? = 100, noReading: Bool = false) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = kmh; f.voltage = v; f.currentA = a; f.temperatureC = temp; f.brake = brake; f.shuttingDown = off
        f.odometerKm = odo; f.temperatureNoReading = noReading; f.ageA = 0.2; f.ageB = 0.2
        return f
    }

    /// 20 minutes at 1 Hz, current swinging 2…22 A; the voltage drops `mOhm` milliohms per amp
    private func sagRide(mOhm: Double) -> [ScooterFrame] {
        (0..<1200).map { k in
            let i = 12 + 10 * sin(Double(k) / 7)
            return frame(Double(k), v: 52 - i * mOhm / 1000, a: i)
        }
    }

    func test_F1_sagReadsTheStrainAndSkipsTheColdStart() {
        XCTAssertEqual(FaultDetectors.f1SagMilliohm(sagRide(mOhm: 65))!, 65, accuracy: 0.5)
        XCTAssertEqual(FaultDetectors.f1SagMilliohm(sagRide(mOhm: 120))!, 120, accuracy: 0.5)
        XCTAssertNil(FaultDetectors.f1SagMilliohm(Array(sagRide(mOhm: 65).prefix(300))), "under 6 min: nothing")
        XCTAssertEqual(FaultDetectors.f1Band(airC: 17.9), "air15")
        XCTAssertEqual(FaultDetectors.f1Band(airC: -2), "air-5")
        XCTAssertEqual(FaultDetectors.f1Band(airC: nil), "air?")
    }

    func test_F1_throughTheGate_healthyQuiet_faultyCaught() {
        var b = FaultBaseline()
        for k in 0..<10 { b = FaultGate.evaluate(b, kind: .f1Sag, value: 62 + Double(k % 4) * 4, day: k).1 }   // 62…74
        var v: FaultVerdict = .normal
        for d in 0..<5 { (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: FaultDetectors.f1SagMilliohm(sagRide(mOhm: 70))!, day: 20 + d); XCTAssertEqual(v, .normal) }
        for d in 0..<3 { (v, b) = FaultGate.evaluate(b, kind: .f1Sag, value: FaultDetectors.f1SagMilliohm(sagRide(mOhm: 120))!, day: 30 + d) }
        if case .alert = v {} else { XCTFail("a strained battery is caught on the 3rd ride") }
    }

    func test_F2_shutOffAtSpeedOnly() {
        var ride = (0..<60).map { frame(Double($0), kmh: 30) }
        XCTAssertEqual(FaultDetectors.f2PowerCutTimes(ride), [])
        ride[20].shuttingDown = true
        ride[40].shuttingDown = true; ride[41].shuttingDown = true
        XCTAssertEqual(FaultDetectors.f2PowerCutTimes(ride), [20, 40], "one cut per shut-off, not per reading")
        var parked = (0..<10).map { frame(Double($0), kmh: 0) }
        parked[5].shuttingDown = true
        XCTAssertEqual(FaultDetectors.f2PowerCutTimes(parked), [], "switching off at a stop is not a cut")
    }

    func test_F3_threeSecondsOfBrakeWithCurrent() {
        var ride = (0..<40).map { frame(Double($0) * 0.5, a: 10) }
        for k in 10..<12 { ride[k].brake = true }                // 0.5 s: the audit's healthy timing overlap
        XCTAssertEqual(FaultDetectors.f3BrakeRuns(ride), [])
        for k in 20..<28 { ride[k].brake = true }                // 3.5 s
        XCTAssertEqual(FaultDetectors.f3BrakeRuns(ride), [13.5])
        var cut = ride
        for k in 20..<28 { cut[k].currentA = 0 }                  // motor cut properly
        XCTAssertEqual(FaultDetectors.f3BrakeRuns(cut), [])
    }

    func test_F5_medianShift_singleBadRidesIgnored() {
        var healthy = Array(repeating: 0.995, count: 20)
        healthy[13] = 1.37; healthy[17] = 1.14                    // GPS trouble on single rides
        XCTAssertLessThan(FaultDetectors.f5ShiftPct(routeRatios: healthy)!, 0.5)
        let worn = Array(repeating: 0.995, count: 10) + Array(repeating: 1.04, count: 10)
        XCTAssertGreaterThan(FaultDetectors.f5ShiftPct(routeRatios: worn)!, 3.3)
        XCTAssertNil(FaultDetectors.f5ShiftPct(routeRatios: Array(repeating: 1, count: 19)))
    }

    func test_F6_modelLearnsTheLoad_overheatStandsOut() {
        let pts = (0..<12).map { k -> FaultDetectors.HeatPoint in
            let e = 8 + Double(k % 5), m = 15 + Double(k * 3 % 20)
            return .init(riseC: 20 + 3 * e + 0.5 * m + (k % 2 == 0 ? 2 : -2), whPerMin: e, minutes: m)
        }
        let model = FaultDetectors.f6Model(pts)!
        XCTAssertLessThan(abs(FaultDetectors.f6OverModelC(.init(riseC: 20 + 30 + 10, whPerMin: 10, minutes: 20), model: model)), 3)
        XCTAssertGreaterThan(FaultDetectors.f6OverModelC(.init(riseC: 20 + 30 + 10 + 14, whPerMin: 10, minutes: 20), model: model), FaultDetectors.f6LineC)
        XCTAssertNil(FaultDetectors.f6Model(Array(pts.prefix(9))), "learn 10 rides first")
        let b = FaultBaseline(), learned = (0..<10).reduce(b) { acc, k in FaultGate.evaluate(acc, kind: .f6Heat, value: Double(k % 5) - 2, day: k).1 }
        XCTAssertEqual(FaultGate.bar(learned, kind: .f6Heat, atLeast: FaultDetectors.f6LineC)!, 10, "the audit's fixed 10 °C line")
    }

    func test_F7_dipsAndImpossibleReadings() {
        var ride = (0..<100).map { frame(Double($0), temp: 40) }
        ride[10].temperatureC = 26; ride[30].temperatureC = 55
        XCTAssertEqual(FaultDetectors.f7Score(ride), 2, "healthy max 2")
        for k in [50, 60, 70] { ride[k].temperatureC = 20 }
        XCTAssertEqual(FaultDetectors.f7Score(ride), 5)
        var noRead = (0..<100).map { frame(Double($0)) }
        noRead[50].temperatureC = nil; noRead[50].temperatureNoReading = true
        XCTAssertEqual(FaultDetectors.f7Score(noRead), 5, "no reading mid-ride without a link drop")
        XCTAssertEqual(FaultDetectors.f7Score(noRead, linkDropTimes: [45]), 0, "after a restart it's expected")
        var wheel = (0..<10).map { frame(Double($0)) }
        wheel[5].speedKmh = 0
        XCTAssertEqual(FaultDetectors.f7Score(wheel, gpsKmhAt: { _ in 25 }), 5)
        XCTAssertEqual(FaultDetectors.f7Score(wheel), 0, "no GPS speed: can't tell")
    }

    func test_F11_parkRules() {
        XCTAssertEqual(FaultDetectors.f11DrainVPerDay(startV: 48.21, endV: 47.21, hours: 24, odoStartKm: 700, odoEndKm: 700, fullV: 54)!, 1, accuracy: 1e-9)
        XCTAssertNil(FaultDetectors.f11DrainVPerDay(startV: 48, endV: 47, hours: 11, odoStartKm: nil, odoEndKm: nil, fullV: 54), "short park")
        XCTAssertNil(FaultDetectors.f11DrainVPerDay(startV: 48, endV: 47, hours: 24, odoStartKm: 700, odoEndKm: 703, fullV: 54), "someone rode it")
        XCTAssertNil(FaultDetectors.f11DrainVPerDay(startV: 48, endV: 52, hours: 24, odoStartKm: nil, odoEndKm: nil, fullV: 54), "charged")
        XCTAssertNil(FaultDetectors.f11DrainVPerDay(startV: 54.22, endV: 53.91, hours: 9.7 + 3, odoStartKm: nil, odoEndKm: nil, fullV: 54.4), "fresh off the charger (audit)")
    }

    func test_F12_restingVoltageSkipsTheFake100() {
        var ride = (0..<30).map { frame(Double($0), kmh: 0, v: 54.4, a: 0.2) }
        for k in 0..<10 { ride[k].voltage = 55 }
        ride[12].voltage = 53.9
        XCTAssertEqual(FaultDetectors.f12RestingVoltage(ride), 54.4)
        XCTAssertEqual(FaultDetectors.f12StepV, 0.5)
    }

    func test_F16_resetBackwardsOrZero_forwardIgnored() {
        XCTAssertTrue(FaultDetectors.f16Reset(previousKm: 1114, nowKm: 0.3))
        XCTAssertTrue(FaultDetectors.f16Reset(previousKm: 1114, nowKm: 900))
        XCTAssertFalse(FaultDetectors.f16Reset(previousKm: 707, nowKm: 1065), "forward across a park: someone else rode")
        XCTAssertFalse(FaultDetectors.f16Reset(previousKm: 1114, nowKm: 1114.2))
        var ride = (0..<30).map { frame(Double($0), odo: 500) }
        ride[5].odometerKm = 900
        XCTAssertFalse(FaultDetectors.f16JumpInRide(ride), "one wrong reading")
        for k in 15..<30 { ride[k].odometerKm = 900 }
        XCTAssertTrue(FaultDetectors.f16JumpInRide(ride))
    }
    // MARK: N10-12 · words, voice, the after-ride pipeline

    func test_N10_12_wording() {
        for k in FaultKind.allCases {
            let t = FaultCopy.text(k)
            XCTAssertFalse(t.title.isEmpty || t.line.isEmpty || t.row.isEmpty || t.what.isEmpty, k.code)
            let all = [t.title, t.line, t.todo ?? "", t.row, t.found, t.what].joined(separator: " ")
            XCTAssertFalse(all.contains("OK to ride") || all.contains("safe to ride"), "never tell the rider it's safe")
            if k.level == .red {
                XCTAssertEqual(t.title, "Something isn't right"); XCTAssertNotNil(t.todo)
            } else {
                XCTAssertNil(t.todo)
            }
        }
        XCTAssertEqual(FaultCopy.notSafe, "It's not safe to keep riding.")
        XCTAssertEqual(FaultCopy.text(.f6Heat).title, "Your motor needs checking")
        XCTAssertEqual(FaultCopy.text(.f11ParkedDrain).title, "Your battery needs checking")
        XCTAssertEqual(FaultCopy.text(.f12FullVoltage).title, "Your charger needs checking")
        XCTAssertEqual(FaultCopy.voiceBrake, "Brakes aren't cutting the motor when braking, check the brake switch and controller.")
    }

    func test_N10_2_N10_3_inRideVoice() {
        var v = LiveFaultVoice(learned: true, brakeFoundBefore: false)
        XCTAssertNil(v.powerCut())
        XCTAssertEqual(v.powerCut(), FaultCopy.voicePowerCut2)
        XCTAssertNil(v.powerCut())
        XCTAssertEqual(v.powerCut(), FaultCopy.voicePowerCut4)
        XCTAssertNil(v.brakeRunEnded(), "1st time → ride summary only")
        var again = LiveFaultVoice(learned: true, brakeFoundBefore: true)
        XCTAssertEqual(again.brakeRunEnded(), FaultCopy.voiceBrake)
        XCTAssertNil(again.brakeRunEnded(), "once per ride")
        var newRider = LiveFaultVoice(learned: false, brakeFoundBefore: true)
        _ = newRider.powerCut()
        XCTAssertNil(newRider.powerCut(), "a new rider hears nothing")
        XCTAssertNil(newRider.brakeRunEnded())
    }

    func test_ruleOuts() {
        XCTAssertEqual(FaultRuleOuts(airC: 2).ruledOut, [.f1Sag, .f6Heat])
        XCTAssertEqual(FaultRuleOuts(airC: 20).ruledOut, [])
        XCTAssertEqual(FaultRuleOuts(airC: nil).ruledOut, [.f6Heat])
        XCTAssertTrue(FaultRuleOuts(airC: 20, minBatteryPct: 12).ruledOut.contains(.f1Sag))
        XCTAssertTrue(FaultRuleOuts(airC: 20, weakGps: true).ruledOut.isSuperset(of: [.f5Tyre, .f7Sensor]))
    }

    private func healthyRide(_ k: Int) -> [ScooterFrame] {
        (0..<900).map { j in
            let i = 12 + 10 * sin(Double(j) / 7)
            return frame(Double(j), v: 52 - i * (62 + Double(k % 4) * 3) / 1000, a: i, odo: 100 + Double(k) * 5 + Double(j) / 300)
        }
    }

    /// HARSH RULE ship check (synthetic): 30 healthy rides → zero findings; then a power cut is caught on the very next ride and
    /// only ONE finding reaches the pop-up even when a second fault shows at the same time
    func test_pipeline_healthyRidesSilent_faultCaught_onePerSummary() {
        var book = FaultBook(), heat = HeatBook()
        var prevOdo: Double?
        for k in 0..<30 {
            let frames = healthyRide(k)
            let rep = AfterRideFaults.run(RideFaultInput(scooterId: "S1", firmware: "1.0", frames: frames, day: k,
                                                         ruleOuts: FaultRuleOuts(airC: 20), previousOdoKm: prevOdo),
                                          book: &book, heat: &heat)
            XCTAssertEqual(rep.findings, [], "healthy ride \(k + 1)")
            prevOdo = frames.last?.odometerKm
        }
        var bad = healthyRide(30)
        bad[400].shuttingDown = true                        // a power cut at 20 km/h
        for j in 600..<610 { bad[j].brake = true }          // and 10 s of brake with current
        let rep = AfterRideFaults.run(RideFaultInput(scooterId: "S1", firmware: "1.0", frames: bad, day: 30,
                                                     ruleOuts: FaultRuleOuts(airC: 20), previousOdoKm: prevOdo),
                                      book: &book, heat: &heat)
        XCTAssertEqual(Set(rep.findings.map(\.kind)), [.f2PowerCut, .f3BrakeCut])
        XCTAssertNotNil(rep.show)
        XCTAssertEqual(rep.show?.kind.level, .red)
        // a different scooter is a new rider: silent
        let other = AfterRideFaults.run(RideFaultInput(scooterId: "S2", frames: bad, day: 30), book: &book, heat: &heat)
        XCTAssertEqual(other.findings, [])
        // firmware change → relearn
        let fw = AfterRideFaults.run(RideFaultInput(scooterId: "S1", firmware: "1.1", frames: bad, day: 31), book: &book, heat: &heat)
        XCTAssertTrue(fw.relearned)
        XCTAssertEqual(fw.findings, [])
    }

    func test_switchOn_chargerAndParkedDrain() {
        var book = FaultBook()
        func charge(_ v: Double, _ d: Int) -> FaultReport {
            let frames = (0..<30).map { frame(Double($0), kmh: 0, v: v, a: 0.1) }
            return AfterRideFaults.switchOn(scooterId: "S", day: d, park: nil, firstFrames: frames, charged: true, book: &book)
        }
        for (k, v) in [54.4, 53.9, 53.4, 54.0, 54.2, 54.1, 53.8, 54.3, 54.0, 53.6, 54.1, 53.9].enumerated() {
            XCTAssertEqual(charge(v, k).findings, [], "normal full \(v) V")
        }
        XCTAssertEqual(charge(52.7, 20).findings, [], "1st low charge: watching")
        XCTAssertEqual(charge(52.6, 21).findings, [])
        XCTAssertEqual(charge(52.5, 22).findings.map(\.kind), [.f12FullVoltage], "3 charges ≥ 0.5 V (+10 %) under the lowest normal")
        let reset = AfterRideFaults.switchOn(scooterId: "S", day: 30, park: (48, 48, 20, 1114, 0.2), firstFrames: [], charged: false,
                                             book: &book)
        XCTAssertEqual(reset.findings.map(\.kind), [.f16OdoReset])
    }
    func test_faultRecords_oneCardPerFault() {
        var list: [FaultRecord] = []
        list = FaultRecord.merge(list, FaultRecord(kind: .f1Sag, scooterId: "S", value: 90, day: 10, odoKm: 1000))
        list = FaultRecord.merge(list, FaultRecord(kind: .f1Sag, scooterId: "S", value: 95, day: 20, odoKm: 1100))
        list = FaultRecord.merge(list, FaultRecord(kind: .f3BrakeCut, scooterId: "S", value: 1, day: 21, odoKm: 1110))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first { $0.kind == .f1Sag }?.value, 95)
        XCTAssertEqual(FaultRecord.open(list, scooterId: "S").first?.kind, .f3BrakeCut, "red first")
        list[0].status = .fixed
        list = FaultRecord.merge(list, FaultRecord(kind: .f1Sag, scooterId: "S", value: 99, day: 40, odoKm: 1300))
        XCTAssertEqual(list.count, 3, "after a fix, a new finding is a new record")
    }
    /// N10-12 wiring: the fault check runs when a ride closes; the pop-up sits over the ride summary; the scooter is only read
    func test_N10_12_wiring() throws {
        let rec = try text("Adapters/RecorderService.swift")
        XCTAssertTrue(rec.contains("FaultService.rideClosed(rideId: id"))
        let root = try text("UI/RootView.swift")
        XCTAssertTrue(root.contains(".overlay { FaultPopupHost() }"))
        let svc = try text("Notifier/FaultService.swift")
        XCTAssertTrue(svc.contains("AfterRideFaults.run(") && svc.contains("ride.isSimulated == false"))
        XCTAssertFalse(svc.contains("writeValue") || svc.contains("ScooterLink"), "read-only: nothing goes to the scooter")
        let pop = try text("UI/Maintenance/FaultPopupView.swift")
        XCTAssertTrue(pop.contains("FaultCopy.notSafe") && pop.contains("exclamationmark.triangle"))
        XCTAssertTrue(pop.contains("FaultCopy.tellMeMore") && pop.contains("FaultCopy.exportReport") && pop.contains("FaultCopy.gotIt"))
    }
    func test_liveTracker_matchesTheAfterRideRules() {
        var ride = (0..<60).map { frame(Double($0) * 0.5, kmh: 30, a: 10) }
        ride[10].shuttingDown = true
        for k in 20..<22 { ride[k].brake = true }      // 0.5 s: nothing
        for k in 30..<38 { ride[k].brake = true }      // 3.5 s
        var tr = LiveFaultTracker()
        var events: [(Double, LiveFaultTracker.Event)] = []
        for f in ride { for e in tr.frame(f) { events.append((f.t, e)) } }
        XCTAssertEqual(events.map(\.1), [.powerCut, .brakeRunEnded])
        XCTAssertEqual(events.last?.0, 19, "said right after the braking ends")
        XCTAssertEqual(FaultDetectors.f2PowerCutTimes(ride).count, 1)
        XCTAssertEqual(FaultDetectors.f3BrakeRuns(ride).count, 1)
    }
    func test_N10_2_N10_3_liveWiring() throws {
        XCTAssertTrue(try text("Adapters/RecorderService.swift").contains("LiveFaultWatch.shared.packet(bytes, at: t)"))
        let w = try text("Audio/LiveFaultWatch.swift")
        XCTAssertTrue(w.contains("LiveFaultTracker()") && w.contains("LiveFaultVoice(learned:"))
        XCTAssertTrue(w.contains("SoundPlayer.shared.cue(.batteryPing") && w.contains("notificationOccurred(.error)"), "L3: ping, voice, vibration")
    }
    // MARK: N10-13 / N10-19 / N10-20 · parts list, tab dot, Home line

    func test_N10_13_partsList_issuesStandOut_neverOK() {
        let open = [FaultRecord(id: "a", kind: .f6Heat, scooterId: "S", value: 12, day: 1, odoKm: 1400)]
        let rem = [PartReminder(id: "brakes", part: .brakes, status: .dueKm(over: 3), name: "Brakes"),
                   PartReminder(id: "tyres", part: .tyres, status: .ok(kmLeft: 80), name: "Tyre pressure"),
                   PartReminder(id: "bolts", part: .bolts, status: .ok(kmLeft: 210), name: "Bolts")]
        let rows = MaintParts.rows(open: open, reminders: rem, ridesLeft: [.electrics: 6], batteryLine: "Health 94% \u{00B7} about 36 km per charge")
        XCTAssertEqual(rows.map(\.part), [.motor, .brakes, .battery, .tyres, .bolts, .electrics], "the mock's order")
        XCTAssertEqual(rows[0].line, "Ran hot on your last 3 rides")
        XCTAssertEqual(rows[1].line, "Check due now")
        XCTAssertEqual(rows[3].line, "Pressure check in 80 km")
        XCTAssertEqual(rows[4].line, "Check in 210 km")
        XCTAssertEqual(rows[5].line, "Learning \u{00B7} about 6 more rides")
        for r in rows { XCTAssertFalse(r.line.contains("OK") || r.line.lowercased().contains("safe to ride"), r.line) }
        XCTAssertTrue(MaintParts.tabDot(rows))
        XCTAssertEqual(MaintParts.homeLine(rows), "Motor \u{00B7} Ran hot on your last 3 rides")
    }

    func test_N10_13_redFirst_quietMeansNoDotNoHomeLine() {
        let open = [FaultRecord(id: "a", kind: .f1Sag, scooterId: "S", value: 1, day: 1, odoKm: nil),
                    FaultRecord(id: "b", kind: .f3BrakeCut, scooterId: "S", value: 1, day: 1, odoKm: nil)]
        let rows = MaintParts.rows(open: open, reminders: [], ridesLeft: [:], batteryLine: nil)
        XCTAssertEqual(rows.first?.part, .brakes)
        XCTAssertTrue(rows.first!.isRed)
        let quiet = MaintParts.rows(open: [], reminders: [PartReminder(id: "tyres", part: .tyres, status: .ok(kmLeft: 50), name: "")],
                                    ridesLeft: [:], batteryLine: nil)
        XCTAssertFalse(MaintParts.tabDot(quiet))
        XCTAssertNil(MaintParts.homeLine(quiet), "nothing when all is quiet")
        XCTAssertEqual(quiet.first { $0.part == .motor }?.line, "Nothing found so far")
    }

    func test_N10_13_ridesLeftAndLog() {
        var book = FaultBook()
        var b = FaultBaseline(); b.samples = [1, 2, 3, 4]
        book.set(b, "S", .f6Heat)
        XCTAssertEqual(MaintParts.ridesLeft(book, scooterId: "S", part: .motor), 6)
        book.set(b, "S", .f5Tyre, "route-1")
        XCTAssertEqual(MaintParts.ridesLeft(book, scooterId: "S", part: .tyres), 6, "a route variant counts")
        XCTAssertEqual(LogWhatIDid.replacedPads.part, .brakes)
        XCTAssertEqual(LogWhatIDid.replacedPads.reminderId, "brakes")
        XCTAssertTrue(LogWhatIDid.replacedBattery.relearns)
        XCTAssertFalse(LogWhatIDid.tyrePressure.relearns, "a check doesn't change the part")
        XCTAssertEqual(PartReminder.part(forReminder: "bolts"), .bolts)
    }
    /// N10-13 / N10-19 / N10-20 / N10-21 wiring
    func test_N10_13_to_21_screens() throws {
        let m = try text("UI/Settings/MaintenanceView.swift")
        XCTAssertTrue(m.contains("MaintenanceService.parts(db)") && m.contains("Log what I did") && m.contains("IssueCard(row: row)"))
        XCTAssertFalse(m.contains("checkmark"), "never a green tick")
        let card = try text("UI/Scooter/MaintenanceCard.swift")
        XCTAssertTrue(card.contains("NavigationLink { BatteryView() } label: { batteryTile }"), "the Battery tile opens the one Battery page")
        XCTAssertTrue(card.contains("[.brakes, .tyres, .motor, .electrics, .bolts]"))
        let scooter = try text("UI/Scooter/ScooterTabView.swift")
        XCTAssertTrue(scooter.contains("MaintenanceCard(rows: partRows"))
        XCTAssertFalse(scooter.contains("Label(\"Battery\", systemImage: Self.batterySymbol"), "the separate Battery row is removed")
        XCTAssertTrue(try text("UI/Battery/BatteryView.swift").contains("BatteryFaultsSection()"), "battery findings on top of the Battery page")
        XCTAssertTrue(try text("UI/Shared/FloatingTabBar.swift").contains("item.id == 4, FaultCenter.shared.tabDot"))
        XCTAssertTrue(try text("UI/Home/HomeView.swift").contains("let line = FaultCenter.shared.homeLine"))
    }
    // MARK: N10-14 · history

    func test_N10_14_historyTimelineAndCounts() {
        let logged = [LoggedWork(id: "l1", what: .replacedTyre, scooterId: "S", day: 300, odoKm: 4780),
                      LoggedWork(id: "l2", what: .tyrePressure, scooterId: "S", day: 100, odoKm: 1800),
                      LoggedWork(id: "x", what: .tyrePressure, scooterId: "OTHER", day: 100, odoKm: 1)]
        let faults = [FaultRecord(id: "f1", kind: .f5Tyre, scooterId: "S", value: 4, day: 297, odoKm: 4760, status: .fixed),
                      FaultRecord(id: "f2", kind: .f6Heat, scooterId: "S", value: 12, day: 200, odoKm: 2900, status: .checkedFine),
                      FaultRecord(id: "f3", kind: .f1Sag, scooterId: "S", value: 90, day: 310, odoKm: 4800)]
        let e = MaintHistory.entries(logged: logged, faults: faults, scooterId: "S", trackedSince: (50, 1150))
        XCTAssertEqual(e.map(\.id), ["f3", "l1", "f1", "f2", "l2", "tracking-started"])
        XCTAssertEqual(e.first { $0.id == "f1" }?.title, "Tyre soft or worn")
        XCTAssertEqual(e.first { $0.id == "f1" }?.outcome, .fixed)
        XCTAssertEqual(e.first { $0.id == "l1" }?.source, .entered)
        XCTAssertEqual(e.last?.source, .measured)
        XCTAssertEqual(MaintHistory.counts(e), HistoryCounts(logged: 2, found: 3, dealtWith: 2, open: 1))
        let years = MaintHistory.byYear(e) { $0 >= 150 ? 2026 : 2025 }
        XCTAssertEqual(years.map(\.year), [2026, 2025])
        XCTAssertEqual(years[1].entries.map(\.id), ["l2", "tracking-started"])
    }
    func test_reportText_bothLanguagesComplete() {
        for k in ReportText.Key.allCases {
            XCTAssertNotEqual(ReportText.t(k, .english), k.rawValue, k.rawValue)
            XCTAssertNotEqual(ReportText.t(k, .hebrew), ReportText.t(k, .english), "Hebrew missing: \(k.rawValue)")
        }
        for f in FaultKind.allCases { XCTAssertNotEqual(ReportText.faultTitle(f, .hebrew), ReportText.faultTitle(f, .english)) }
        for w in LogWhatIDid.allCases { XCTAssertNotEqual(ReportText.logTitle(w, .hebrew), w.title) }
        XCTAssertTrue(ReportLanguage.hebrew.rightToLeft)
        let all = ReportText.Key.allCases.map { ReportText.t($0, .english) }.joined(separator: " ")
        XCTAssertTrue(all.contains("No places, routes or times of day"))
    }
    func test_N10_14_historyWiring() throws {
        XCTAssertTrue(try text("UI/Settings/MaintenanceView.swift").contains("MaintenanceHistoryView()"), "History from the clock button")
        let h = try text("UI/Maintenance/MaintenanceHistoryView.swift")
        XCTAssertTrue(h.contains("Button(\"English\")") && h.contains("Button(\"עברית\")"), "language pop-up before export")
        XCTAssertTrue(h.contains("MaintHistory.counts(entries)") && h.contains("90 % \u{00B7} first notice"))
        let pdf = try text("UI/Maintenance/ReportPDF.swift")
        XCTAssertTrue(pdf.contains("\"ArialMT\"") && pdf.contains("\"Arial-BoldMT\""), "one font")
        XCTAssertTrue(pdf.contains(".rightToLeft"))
        XCTAssertFalse(pdf.contains(".lat") || pdf.contains("placeId") || pdf.contains("routeId"), "no places or routes")
    }
    // MARK: N10-15 · mechanic report

    func test_N10_15_textsOccurrencesTrend() {
        for k in MechanicText.Key.allCases { XCTAssertNotEqual(MechanicText.t(k, .hebrew), MechanicText.t(k, .english), k.rawValue) }
        for f in FaultKind.allCases {
            XCTAssertNotEqual(MechanicText.found(f, .hebrew), MechanicText.found(f, .english))
            XCTAssertNotEqual(MechanicText.what(f, .hebrew), MechanicText.what(f, .english))
        }
        XCTAssertEqual(MechanicText.trend([60, 61, 62, 80, 85, 90], higherIsWorse: true), 1)
        XCTAssertEqual(MechanicText.trend([60, 61, 60], higherIsWorse: true), 0)
        XCTAssertEqual(MechanicText.trend([54, 53, 52], higherIsWorse: false), 1, "voltage dropping = worse")
        var ride = (0..<120).map { frame(Double($0), kmh: 30, a: 12, odo: 1000 + Double($0) / 100) }
        ride[60].shuttingDown = true
        let occ = FaultOccurrence.fromRide(kinds: [.f2PowerCut, .f1Sag], values: [.f1Sag: 90], frames: ride, scooterId: "S",
                                           rideId: "R", day: 10, airC: 18)
        XCTAssertEqual(occ.count, 2)
        let cut = occ.first { $0.kind == .f2PowerCut }!
        XCTAssertEqual(cut.minutesIn!, 1, accuracy: 0.01)
        XCTAssertEqual(cut.speedKmh, 30)
        XCTAssertEqual(occ.first { $0.kind == .f1Sag }?.value, 90)
        let many = FaultOccurrence.append([], Array(repeating: cut, count: 40))
        XCTAssertEqual(many.count, 30, "newest 30 kept")
    }
    func test_N10_15_reportWiring() throws {
        let root = try text("UI/RootView.swift")
        XCTAssertTrue(try text("UI/Maintenance/FaultPopupView.swift").contains("onExport: { exporting = r }"))
        let pop = try text("UI/Maintenance/FaultPopupView.swift")
        XCTAssertTrue(pop.contains("Button(\"English\")") && pop.contains("Button(\"עברית\")"), "language pop-up")
        let pdf = try text("UI/Maintenance/ReportPDF.swift")
        XCTAssertTrue(pdf.contains("MechanicText.t(.leadsLater") || pdf.contains("m(.leadsLater)"), "no Leads until a mechanic checked them")
        XCTAssertTrue(pdf.contains("abs($0 - s) <= 120"), "CSV: ±2 min around each event")
        XCTAssertFalse(pdf.contains("Leads for the workshop:"), "no invented causes")
    }
    func test_N10_2_N10_3_redLights() throws {
        XCTAssertEqual(WarningLight.powerCut.colour, .red)
        XCTAssertEqual(WarningLight.brakeFault.colour, .red)
        var strip = WarningStrip()
        strip.update(on: [.rainSoon, .offlineMap, .gearReminder, .brakeFault], wheelSpeedKmh: 20, at: 0)
        XCTAssertEqual(strip.shown.first, .brakeFault, "red first")
        XCTAssertTrue(try text("Adapters/RecorderService.swift").contains("input.powerCutLight = LiveFaultWatch.shared.powerCutLight"))
    }
}
