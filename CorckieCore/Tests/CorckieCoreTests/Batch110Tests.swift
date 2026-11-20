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
}
