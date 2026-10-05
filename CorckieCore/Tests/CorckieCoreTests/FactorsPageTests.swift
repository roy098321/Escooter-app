import XCTest
@testable import CorckieCore

/// M4-08: the Factors page rows (effect + "based on N rides", or the progress line below the gate).
final class FactorsPageTests: XCTestCase {
    private func e(_ id: String, _ level: String, _ q: FactorQuantity, _ v: Double?, n: Int = 6, w: Int = 6, scope: FactorScope = .route) -> FactorEffect {
        InsightSamples.effect(id, level, q, v, n: n, nWithout: w, scope: scope)
    }

    func testRouteRowWithTimeAndBattery() {
        let rows = FactorsPage.rows([e("W1", "head", .time, 60), e("W1", "head", .used, 1.2)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "Headwind")
        XCTAssertEqual(rows[0].timeText, "+1 min per trip")
        XCTAssertEqual(rows[0].batteryText, "+1% battery per trip")
        XCTAssertEqual(rows[0].basedOn, "based on 12 rides")
        XCTAssertNil(rows[0].progress)
    }

    func testPooledPerKm() {
        let rows = FactorsPage.rows([e("W3", "wet", .time, 8, scope: .pooled), e("W3", "wet", .used, 0.4, scope: .pooled)])
        XCTAssertEqual(rows[0].title, "Wet roads")
        XCTAssertEqual(rows[0].timeText, "+8 s per km")
        XCTAssertEqual(rows[0].batteryText, "+0.40% battery per km")
        let load = FactorsPage.rows([e("L1", "perKg", .used, 0.05, scope: .pooled)])
        XCTAssertEqual(load[0].title, "Load")
        XCTAssertEqual(load[0].batteryText, "+0.05% battery per km per kg")
    }

    func testBelowTheGateShowsProgressAndNoNumber() {
        let rows = FactorsPage.rows([e("W1", "head", .time, nil, n: 2, w: 5), e("W1", "head", .used, nil, n: 2, w: 5)])
        XCTAssertEqual(rows[0].progress, "2 of 3 windy rides")
        XCTAssertNil(rows[0].timeText)
        XCTAssertNil(rows[0].batteryText)
        XCTAssertNil(rows[0].basedOn)
        XCTAssertFalse(rows[0].hasEffect)
    }

    func testEffectsFirstThenProgress() {
        let rows = FactorsPage.rows([e("W3", "wet", .time, nil, n: 1, w: 8), e("T1", "rush", .time, 90)])
        XCTAssertEqual(rows.map(\.title), ["Rush hour", "Wet roads"])
        XCTAssertEqual(rows[0].timeText, "+1.5 min per trip")
        XCTAssertEqual(rows[1].progress, "1 of 3 wet rides")
    }

    func testNegativeEffect() {
        let rows = FactorsPage.rows([e("W1", "tail", .time, -45), e("W1", "tail", .used, -0.7)])
        XCTAssertEqual(rows[0].title, "Tailwind")
        XCTAssertEqual(rows[0].timeText, "\u{2212}45 s per trip")
        XCTAssertEqual(rows[0].batteryText, "\u{2212}0.7% battery per trip")
    }

    func testAnswerRowsNeedThree() {
        XCTAssertTrue(FactorsPage.answerRows(counts: [.tyresSoft: 2]).isEmpty)
        let rows = FactorsPage.answerRows(counts: [.tyresSoft: 3, .heavy: 5])
        XCTAssertEqual(rows.map(\.title), ["Soft tyres"])
        XCTAssertTrue(rows[0].basedOn?.contains("3 times") ?? false)
    }

    func testNoRewardWords() {
        let rows = FactorsPage.rows([e("W1", "head", .time, 60), e("W1", "head", .used, 1.2), e("W3", "wet", .time, nil, n: 1, w: 8)])
            + FactorsPage.answerRows(counts: [.tyresSoft: 3])
        for r in rows {
            for text in [r.title, r.timeText, r.batteryText, r.basedOn, r.progress].compactMap({ $0 }) {
                XCTAssertEqual(InsightText.bannedIn(text), [], text)
            }
        }
        XCTAssertEqual(InsightText.bannedIn(FactorsPage.emptyText), [])
    }
}
