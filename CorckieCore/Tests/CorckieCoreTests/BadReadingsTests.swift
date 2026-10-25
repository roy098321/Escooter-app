import XCTest
@testable import CorckieCore

/// Notes 12 + 10: bad scooter readings are trimmed, never the whole ride; a warm-up after scooter-on; trust returns once the
/// readings look normal; a real format change is still found; ignored readings per kind, said plainly only when they changed a
/// visible number. Made-up frames, ten a second.
final class BadReadingsTests: XCTestCase {
    private func frame(_ t: Double, bad: Bool) -> ScooterFrame {
        var f = ScooterFrame(t: t)
        f.speedKmh = 20
        f.voltage = bad ? 0 : 50          // 0 V is outside T05: that reading is dropped
        f.batteryPct = 80
        return f
    }

    /// Feeds packet-A frames from `from` to `to` (10 a second); `bad(t)` says which fail
    private func feed(_ g: inout Plausibility, from: Double, to: Double, bad: (Double) -> Bool) {
        var t = from
        while t < to {
            _ = g.check(frame(t, bad: bad(t)), isPacketA: true)
            t += 0.1
        }
    }

    func test_note12_garbledFirstSecondsAfterScooterOn_doNotTripTheWatch() {
        var g = Plausibility()
        g.connected(at: 0)
        // the lift: every other reading garbled for 25 s, so they never settle
        feed(&g, from: 0, to: 25, bad: { Int(($0 * 10).rounded()) % 2 == 0 })
        XCTAssertTrue(g.warmingUp(at: 25))
        XCTAssertFalse(g.formatChanged, "no judging during the warm-up")
        XCTAssertGreaterThan(g.ignoredReadings, 0, "the bad readings themselves are still dropped")
        feed(&g, from: 25, to: 120, bad: { _ in false })
        XCTAssertFalse(g.formatChanged)
        XCTAssertFalse(g.warmingUp(at: 120))
    }

    func test_note12_realFormatChange_isStillFound_andTrustReturns() {
        var g = Plausibility()
        g.connected(at: 0)
        feed(&g, from: 0, to: 2, bad: { _ in false })          // settles
        XCTAssertFalse(g.warmingUp(at: 2))
        feed(&g, from: 2, to: 30, bad: { _ in true })          // the format really changed
        XCTAssertTrue(g.formatChanged)
        XCTAssertTrue(g.failedShareTripped)
        feed(&g, from: 30, to: 120, bad: { _ in false })       // normal again
        XCTAssertFalse(g.formatChanged, "trust comes back")
        XCTAssertTrue(g.formatChangeSeen)
        XCTAssertEqual(g.trustRecovered, 1)
    }

    func test_note12_aNewConnectionIsJudgedAfresh() {
        var g = Plausibility()
        g.connected(at: 0)
        feed(&g, from: 0, to: 2, bad: { _ in false })
        feed(&g, from: 2, to: 30, bad: { _ in true })
        XCTAssertTrue(g.failedShareTripped)
        g.connected(at: 40)
        XCTAssertFalse(g.formatChanged)
        XCTAssertFalse(g.failedShareTripped, "one false alarm no longer sticks to every later ride")
    }

    func test_note12_engineTrustsTheScooterAgain() {
        var feedLine = RideFeed()
        feedLine.engine.handle(.connected, at: 0)
        feedLine.engine.handle(.formatChanged, at: 1)
        XCTAssertNotNil(feedLine.engine.untrustedSince)
        feedLine.engine.handle(.formatRecovered, at: 2)
        XCTAssertNil(feedLine.engine.untrustedSince)
    }

    func test_note10_perKind_andPlainWordsOnlyWhenItChangedANumber() {
        var x = IgnoredReadings()
        x.add([.speed], speedKmh: 87, batteryPct: nil, tempC: nil)
        x.add([.voltage], speedKmh: nil, batteryPct: nil, tempC: nil)
        x.add([.battery], speedKmh: nil, batteryPct: 79, tempC: nil)
        XCTAssertEqual(x.total, 3)
        XCTAssertEqual(x.notes(topSpeedKmh: 32, startPct: 80, endPct: 74, tempPeakC: 40),
                       ["Top speed ignores a jump to 87 km/h that wasn't real"], "79 % lies inside 80 → 74: it changed nothing")
        XCTAssertEqual(x.infoLine, "Ignored readings: speed 1 \u{00B7} battery 1 \u{00B7} voltage 1")
        var y = IgnoredReadings()
        y.add([.voltage], speedKmh: nil, batteryPct: nil, tempC: nil)
        XCTAssertEqual(y.notes(topSpeedKmh: 32, startPct: 80, endPct: 74, tempPeakC: 40), [], "a voltage reading is not on the screen")
        var z = IgnoredReadings()
        z.add([.battery], speedKmh: nil, batteryPct: 12, tempC: nil)
        XCTAssertEqual(z.notes(topSpeedKmh: 30, startPct: 80, endPct: 74, tempPeakC: nil), ["Battery ignores a reading of 12 % that wasn't real"])
    }

    func test_note10_summaryNote_onlyWithLines() {
        var input = RideDetailInput(startAt: 0, ignoredReadings: 4)
        input.ignoredNotes = []
        XCTAssertFalse(RideSummaryBuilder.build(input, gaps: [], points: []).notes.contains { $0.kind == .ignored }, "nothing visible changed: no note")
        input.ignoredNotes = ["Top speed ignores a jump to 87 km/h that wasn't real"]
        input.ignoredInfo = "Ignored readings: speed 4"
        let m = RideSummaryBuilder.build(input, gaps: [], points: [])
        XCTAssertEqual(m.notes.filter { $0.kind == .ignored }.map(\.text), ["Top speed ignores a jump to 87 km/h that wasn't real."])
        XCTAssertTrue(m.infoLines.contains("Ignored readings: speed 4"))
    }

    func test_note10_extrasRoundTrip() {
        var e = RideExtras()
        e.ignored = IgnoredReadings(byKind: ["speed": 2], maxSpeedKmh: 87)
        e.ignoredNotes = ["Top speed ignores a jump to 87 km/h that wasn't real"]
        XCTAssertEqual(RideExtras.parse(e.json), e)
    }
}
