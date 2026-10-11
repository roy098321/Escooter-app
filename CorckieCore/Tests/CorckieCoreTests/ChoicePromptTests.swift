import XCTest
@testable import CorckieCore

/// M6-02 (Q23 live): prompts at the choice points of the followed combination, driven by made-up rides (`ChoiceSamples`) through
/// the live screen driver: ~15 s ahead, >= 20 s saving, options >= 30 m apart, one at a time, outranks other banners, gone once
/// passed, the other way taken = quiet re-plan.
final class ChoicePromptTests: XCTestCase {
    typealias S = ChoiceSamples.Spec

    private struct Setup {
        var combo: FastestCombo
        var points: [ChoicePoint]
    }

    private func setup() -> Setup {
        let made = ChoiceSamples.answer(ChoiceSamples.nineRides)
        guard case .combination(let c) = made.answer.state else { fatalError("expected a combination") }
        return Setup(combo: c, points: made.set.points)
    }

    private struct Step {
        var t: Double
        var alongM: Double
        var text: String?
        var banner: LiveBanner?
        var offRoute: Bool
    }

    /// A ride of the spec at the sample's speeds through the live screen driver (fix every 2 s, speed 22 km/h on screen).
    private func ride(_ setup: Setup, spec: S, prompter: ChoicePrompter?, hot: Bool = false) -> (steps: [Step], driver: LiveScreenDriver) {
        var d = LiveScreenDriver()
        let follower = RouteFollower(destinationName: "Work", path: setup.combo.path, todayS: setup.combo.timeS)
        d.follow(follower, prompts: prompter)
        let made = ChoiceSamples.ride(id: "x", startAt: ChoiceSamples.t0, spec: spec, seed: 99).choice
        var steps: [Step] = []
        var along = 0.0
        var last: GeoPoint?
        for fix in made.fixes {
            let p = GeoPoint(lat: fix.lat, lon: fix.lon)
            if let l = last { along += Geo.distanceM(l, p) }
            last = p
            let input = LiveInput(scooterSpeedKmh: 22, scooterLinked: true, scooterBatteryPct: 80, phase: .riding,
                                  scooterTempC: hot ? 101 : nil, lat: fix.lat, lon: fix.lon, rideElapsedS: fix.t, rideDistanceM: along)
            let s = d.update(input, at: 100 + fix.t)
            steps.append(Step(t: fix.t, alongM: along, text: s.bannerText, banner: s.banner?.banner, offRoute: s.arrival?.offRoute ?? false))
        }
        return (steps, d)
    }

    private func prompts(_ steps: [Step]) -> [Step] { steps.filter { $0.banner == .choicePoint } }

    func testPromptComesAbout15SecondsAheadAndGoesAfterTheSplit() {
        let s = setup()
        let r = ride(s, spec: S(.park, left: true), prompter: ChoicePrompter(combo: s.combo, points: s.points))
        let shown = prompts(r.steps)
        XCTAssertFalse(shown.isEmpty)
        // first split at 800 m: the prompt starts 13...16 s before it (6 m/s => 78...96 m)
        let first = shown.first!
        XCTAssertGreaterThanOrEqual(800 - first.alongM, 70)
        XCTAssertLessThanOrEqual(800 - first.alongM, 100)
        XCTAssertTrue(first.text!.contains("saves ~"), first.text ?? "")
        XCTAssertTrue(first.text!.hasPrefix("Keep right"), first.text ?? "")      // the park detour bends east
        // stays until 30 m past the split, then nothing until the second one
        let firstGroup = shown.filter { $0.alongM < 1_500 }
        XCTAssertGreaterThanOrEqual(firstGroup.last!.alongM, 800)
        XCTAssertLessThanOrEqual(firstGroup.last!.alongM, 800 + 60)
        let between = r.steps.filter { $0.alongM > 900 && $0.alongM < 2_200 }
        XCTAssertTrue(between.allSatisfy { $0.banner != .choicePoint })
        let second = shown.filter { $0.alongM > 2_000 }
        XCTAssertFalse(second.isEmpty)
        XCTAssertTrue(second.first!.text!.hasPrefix("Keep left"), second.first!.text ?? "")
        XCTAssertEqual(r.driver.promptsShownNow, 2)
        XCTAssertEqual(r.steps.filter { $0.offRoute }.count, 0)
    }

    func testNoPromptWithoutAPrompter() {
        let s = setup()
        let r = ride(s, spec: S(.park, left: true), prompter: nil)
        XCTAssertTrue(prompts(r.steps).isEmpty)
    }

    func testSmallSavingOrCloseOptionsGiveNoPrompt() {
        let s = setup()
        var small = s.combo
        small.ways = small.ways.map { var w = $0; w.savingS = 15; return w }          // < 20 s
        let r1 = ride(s, spec: S(.park, left: true), prompter: ChoicePrompter(combo: small, points: s.points))
        XCTAssertTrue(prompts(r1.steps).isEmpty)
        var close = s.combo
        close.ways = close.ways.map { var w = $0; w.apartM = 20; return w }           // < 30 m
        let r2 = ride(s, spec: S(.park, left: true), prompter: ChoicePrompter(combo: close, points: s.points))
        XCTAssertTrue(prompts(r2.steps).isEmpty)
        // 20 s saving is not enough once the 10% margin is on it (22 s), 23 s is
        var edge = s.combo
        edge.ways = edge.ways.map { var w = $0; w.savingS = 21; return w }
        XCTAssertTrue(prompts(ride(s, spec: S(.park, left: true), prompter: ChoicePrompter(combo: edge, points: s.points)).steps).isEmpty)
        edge.ways = edge.ways.map { var w = $0; w.savingS = 23; return w }
        XCTAssertFalse(prompts(ride(s, spec: S(.park, left: true), prompter: ChoicePrompter(combo: edge, points: s.points)).steps).isEmpty)
    }

    func testUsualWayWhereItIsFastestSaysStay() {
        let s = setup()
        var usual = s.combo
        // pretend the first choice point's fastest is the usual way
        guard let cp = s.points.first, let ref = cp.options.first(where: { $0.isReference }) else { return XCTFail("no choice point") }
        var w = usual.ways[0]
        w.optionId = ref.id
        w.name = ref.name
        w.isReference = true
        w.savingS = 40
        usual.ways[0] = w
        let path = FastestCombination.path(reference: ChoiceSamples.reference, points: s.points, chosen: usual.ways)
        usual.path = path
        let pr = ChoicePrompter(combo: usual, points: s.points)
        var d = LiveScreenDriver()
        d.follow(RouteFollower(destinationName: "Work", path: path, todayS: 600), prompts: pr)
        let made = ChoiceSamples.ride(id: "x", startAt: ChoiceSamples.t0, spec: S(.usual, left: true), seed: 3).choice
        var texts: [String] = []
        var along = 0.0
        var last: GeoPoint?
        for fix in made.fixes {
            let p = GeoPoint(lat: fix.lat, lon: fix.lon)
            if let l = last { along += Geo.distanceM(l, p) }
            last = p
            let s2 = d.update(LiveInput(scooterSpeedKmh: 22, scooterBatteryPct: 80, lat: fix.lat, lon: fix.lon, rideElapsedS: fix.t, rideDistanceM: along), at: fix.t)
            if s2.banner?.banner == .choicePoint, let t = s2.bannerText, !texts.contains(t) { texts.append(t) }
        }
        XCTAssertTrue(texts.first?.hasPrefix("Stay on the usual way") == true, texts.first ?? "none")
        XCTAssertTrue(texts.first?.contains("saves ~40 s") == true, texts.first ?? "none")
    }

    func testTheOtherWayTakenIsAQuietReplan() {
        let s = setup()
        // combination = park first; the rider goes the usual way at the first point and left at the second
        let r = ride(s, spec: S(.usual, left: true), prompter: ChoicePrompter(combo: s.combo, points: s.points))
        XCTAssertNotEqual(r.driver.followedPath?.count, s.combo.path.count)
        let after = r.steps.filter { $0.alongM > 900 && $0.alongM < 2_200 }
        XCTAssertTrue(after.allSatisfy { $0.banner != .choicePoint })
        XCTAssertTrue(after.allSatisfy { !$0.offRoute }, "the follower stayed on the (re-planned) path")
        // the second point is still prompted
        XCTAssertFalse(r.steps.filter { $0.alongM > 2_000 && $0.banner == .choicePoint }.isEmpty)
        // the re-plan says nothing: no banner other than prompts
        XCTAssertTrue(r.steps.allSatisfy { $0.banner == nil || $0.banner == .choicePoint })
    }

    func testPromptOutranksOtherBannersButNotVeryHot() {
        let s = setup()
        let r = ride(s, spec: S(.park, left: true), prompter: ChoicePrompter(combo: s.combo, points: s.points), hot: true)
        // the motor is very hot all ride: the banner is "very hot", never the prompt
        XCTAssertTrue(r.steps.allSatisfy { $0.banner == .veryHot })
        // the prompter still counted the prompts for the ride's developer line
        XCTAssertEqual(r.driver.promptsShownNow, 2)
    }

    func testQueueHoldKeepsTheBannerPastEightSecondsAndClearTakesItAway() {
        var q = BannerQueue()
        q.hold(.choicePoint, true)
        q.raise(.choicePoint, at: 0)
        XCTAssertEqual(q.tick(at: 0, speedKmh: 20)?.banner, .choicePoint)
        XCTAssertEqual(q.tick(at: 20, speedKmh: 20)?.banner, .choicePoint)
        q.clear(.choicePoint)
        XCTAssertNil(q.tick(at: 21, speedKmh: 20))
        q.hold(.choicePoint, false)
        q.raise(.choicePoint, at: 30)
        XCTAssertEqual(q.tick(at: 30, speedKmh: 20)?.banner, .choicePoint)
        XCTAssertNil(q.tick(at: 39, speedKmh: 20))
    }

    func testPointsOffThePathAreLeftOut() {
        let s = setup()
        let p = ChoicePrompter(combo: s.combo, points: s.points)
        XCTAssertEqual(p?.pendingCount, 2)
        var broken = s.combo
        broken.ways[0].split = GeoPoint(lat: 11, lon: -30)
        XCTAssertEqual(ChoicePrompter(combo: broken, points: s.points)?.pendingCount, 1)
    }
}
