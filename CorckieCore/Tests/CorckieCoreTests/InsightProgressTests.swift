import XCTest
@testable import CorckieCore

/// Note 9: progress bar with early read / confident marks, a range that shrinks (and says when it widens), pages once confident.
final class InsightProgressTests: XCTestCase {
    func testLearningShowsTheCountToAFirstRead() {
        let made = InsightProgressBuilder.make([.learning(.sweetSpot, "5 of 12 steady stretches"), .learning(.wind, "1 of 8 rides with wind data")])
        XCTAssertEqual(made.progress.count, 1, "wind stays a Home card")
        let p = made.progress[0]
        XCTAssertEqual(p.stage, .learning)
        XCTAssertEqual(p.have, 5)
        XCTAssertEqual(p.countLine, "5 of 12 steady stretches to a first read")
        XCTAssertEqual(p.earlyMark, 12.0 / 30, accuracy: 0.001)
        XCTAssertEqual(p.fraction, 5.0 / 30, accuracy: 0.001)
        XCTAssertNil(p.range)
        XCTAssertTrue(made.pages.isEmpty)
    }

    func testWordsWithoutACount() {
        let p = InsightProgressBuilder.make([.learning(.sweetSpot, "no clear lowest point yet")]).progress[0]
        XCTAssertNil(p.have)
        XCTAssertEqual(p.countLine, "Not yet: no clear lowest point yet")
    }

    func testRangeFromTheInterval() {
        let a = InsightProgressBuilder.range("Sweet spot between 26 and 30 km/h.")
        XCTAssertEqual(a?.text, "26\u{2013}30 km/h")
        XCTAssertEqual(a?.width, 4)
        let b = InsightProgressBuilder.range("Between +1 and +3 % per km.")
        XCTAssertEqual(b?.text, "+1\u{2013}+3 % per km")
        XCTAssertEqual(b?.width, 2)
        XCTAssertEqual(InsightProgressBuilder.range("Leaving then saves between 4 and 9 min.")?.text, "4\u{2013}9 min")
        XCTAssertNil(InsightProgressBuilder.range("Leaving then saves up to 9 min."))
    }

    func testEarlyReadAndConfidentFromTheSamples() {
        let made = InsightProgressBuilder.make(InsightSamplesF21.outcomes())
        // every sample card is either a page (High) or a progress card (Medium = early read with a range)
        for p in made.progress where p.stage == .early {
            XCTAssertNotNil(p.card)
            XCTAssertNotNil(p.range)
            XCTAssertTrue(p.countLine.hasSuffix("to confident"))
        }
        for page in made.pages { XCTAssertEqual(page.card.certainty.level, .high) }
        XCTAssertFalse(made.progress.contains { $0.topic == .wind })
    }

    func testAWiderRangeSaysSo() {
        guard let card = InsightSamplesF21.outcomes().compactMap(\.card).first(where: { $0.topic != .wind }) else { return XCTFail("no sample card") }
        var c = card
        c.certainty.level = .medium
        c.certainty.interval = "Sweet spot between 20 and 28 km/h."
        let first = InsightProgressBuilder.make([.card(c)], previousWidths: [c.topic.rawValue: 4])
        XCTAssertEqual(first.progress.first?.widened, true)
        XCTAssertNotNil(first.progress.first?.widenedLine)
        XCTAssertEqual(first.widths[c.topic.rawValue], 8)
        let narrower = InsightProgressBuilder.make([.card(c)], previousWidths: [c.topic.rawValue: 10])
        XCTAssertEqual(narrower.progress.first?.widened, false)
    }

    func testConfidentGraduatesToAPage() {
        guard var c = InsightSamplesF21.outcomes().compactMap(\.card).first(where: { $0.topic == .sweetSpot }) else { return XCTFail("no sweet spot") }
        c.certainty.level = .high
        let made = InsightProgressBuilder.make([.card(c)])
        XCTAssertTrue(made.progress.isEmpty, "no bar once confident")
        XCTAssertEqual(made.pages.map(\.page), [.speed])
        XCTAssertEqual(InsightPage.allCases.map(\.rawValue), ["Speed", "Battery", "Charging", "Hills", "Wind", "Temperature", "Routes & places",
                                                              "Distance & time", "Money & environment", "Scooter health"])
    }
}
