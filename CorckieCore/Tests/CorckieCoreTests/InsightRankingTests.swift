import XCTest
@testable import CorckieCore

/// M4-03: ranking (9.3), the freshness penalty, "N more" order, the ride-start pick (9.4), dedupe / cooldown, expiry,
/// Recent insights and the weather-arrives re-run.
final class InsightRankingTests: XCTestCase {
    private let now = InsightSamples.now
    private let day = FactorSamples.day

    private func make(_ t: InsightType, ride: String? = "r1", time: Double? = nil, used: Double? = nil, at: Int64? = nil, progress: Bool = false,
                      subject: String? = nil, week: Int64? = nil) -> Insight {
        Insight(type: t, rideId: ride, routeId: "A", weekStart: week, subject: subject, text: "\(t.rawValue)", basedOnN: 5, timeS: time, usedPct: used,
                isProgress: progress, createdAt: at ?? now)
    }

    func test_score_classPlusSizeCapped() {
        XCTAssertEqual(InsightRanking.score(make(.q9Live), recentTopTypes: []), 100)
        XCTAssertEqual(InsightRanking.score(make(.q4After, time: 120, used: 1), recentTopTypes: []), 80 + 10 + 3)
        XCTAssertEqual(InsightRanking.score(make(.q4After, time: -600, used: 5), recentTopTypes: []), 100, "size is capped at 20, sign does not matter")
        XCTAssertEqual(InsightRanking.score(make(.q15After, time: 60), recentTopTypes: []), 35)
        XCTAssertEqual(InsightRanking.score(make(.q17New), recentTopTypes: []), 40)
        XCTAssertEqual(InsightRanking.score(make(.q1After, time: 60), recentTopTypes: [.q1After]), 60 + 5 - 15)
        XCTAssertEqual(InsightRanking.score(make(.q4After, progress: true), recentTopTypes: []), 0)
        // the stored score is the plain one
        XCTAssertEqual(make(.q18, time: 60).score, 65)
    }

    func test_rank_orderByClassThenSize() {
        let all = [make(.q15After, time: 60), make(.q17New), make(.q1After, time: 120), make(.q4After, time: 60), make(.firstRide, ride: "r1")]
        let r = InsightRanking.rank(all, recentTopTypes: [], nowMs: now)
        XCTAssertEqual(r.top?.type, .q4After)
        XCTAssertEqual(r.more.map(\.type), [.q1After, .q17New, .firstRide, .q15After], "N more expands in score order (ties: catalogue order)")
        XCTAssertEqual(r.moreText, "4 more")
        XCTAssertEqual(r.progress, [])
    }

    func test_rank_freshnessPenalty_lastThreeRidesOnly() {
        let q4 = make(.q4After, time: 30)              // 80 + 2.5
        let q1 = make(.q1After, time: 240, used: 3)    // 60 + 20
        XCTAssertEqual(InsightRanking.rank([q4, q1], recentTopTypes: [], nowMs: now).top?.type, .q4After)
        // q4 was the top card on the ride before: 67.5 < 80
        XCTAssertEqual(InsightRanking.rank([q4, q1], recentTopTypes: [.q15After, .q4After], nowMs: now).top?.type, .q1After)
        // four rides ago does not count
        XCTAssertEqual(InsightRanking.rank([q4, q1], recentTopTypes: [.q15After, .q18, .q3After, .q4After], nowMs: now).top?.type, .q4After)
    }

    func test_rank_progressNeverTop_expiredAndDismissedLeftOut() {
        var dismissed = make(.q4After, time: 60)
        dismissed.dismissedAt = now
        let start = make(.q15Live, time: 120, at: now - 3 * 3_600_000)         // 2 h lifetime: expired
        let p = make(.q15After, progress: true)
        let r = InsightRanking.rank([dismissed, start, p, make(.q22Weekly, ride: nil, week: 0)], recentTopTypes: [], nowMs: now)
        XCTAssertEqual(r.top?.type, .q22Weekly)
        XCTAssertEqual(r.more, [])
        XCTAssertEqual(r.progress.map(\.type), [.q15After])
        XCTAssertNil(InsightRanking.rank([p], recentTopTypes: [], nowMs: now).top)
    }

    func test_expiry_perMoment() {
        XCTAssertEqual(make(.q1Live).expiresAt, now + 2 * 3_600_000)
        XCTAssertFalse(make(.q1Live).isExpired(at: now + 2 * 3_600_000 - 1))
        XCTAssertTrue(make(.q1Live).isExpired(at: now + 2 * 3_600_000))
        XCTAssertEqual(make(.q15Notify).expiresAt, now + day)
        XCTAssertEqual(make(.q22Weekly, week: 0).expiresAt, now + 14 * day)
        XCTAssertNil(make(.q4After).expiresAt, "after-ride cards stay")
    }

    func test_startPick_twoInC24Order_restToSummary() {
        let cands = [make(.q15Live, time: 120), make(.q1Live), make(.q9Live), make(.q4After, time: 60)]
        let pick = InsightRanking.startPick(cands)
        XCTAssertEqual(pick.shown.map(\.type), [.q9Live, .q1Live])
        XCTAssertEqual(pick.toSummary.map(\.type), [.q15Live])
        // battery tight comes before the return check (C24 row 4, then the banner order)
        XCTAssertEqual(InsightRanking.startPick([make(.q9Live), make(.q2Live)]).shown.map(\.type), [.q2Live, .q9Live])
    }

    func test_ids_deterministic_perScope() {
        XCTAssertEqual(make(.q4After).id, "q4After:r1")
        XCTAssertEqual(make(.q4After, progress: true).id, "q4After:r1:progress")
        XCTAssertEqual(make(.q22Weekly, ride: nil, week: 123).id, "q22Weekly:w123")
        XCTAssertEqual(make(.q17New, subject: "c9").id, "q17New:c9")
        XCTAssertEqual(make(.q17New, ride: "r2", subject: "c9").id, "q17New:c9", "once per climb, whichever ride")
        XCTAssertEqual(make(.q15Notify, ride: nil, subject: "A").id, "q15Notify:A:d\(now / day)")
        // stored type round trip
        let p = make(.q19After, progress: true)
        XCTAssertEqual(p.storedType, "progress.q19After")
        XCTAssertEqual(Insight.parse(storedType: p.storedType)?.type, .q19After)
        XCTAssertEqual(Insight.parse(storedType: p.storedType)?.progress, true)
        XCTAssertEqual(Insight.parse(storedType: "q4After")?.progress, false)
        XCTAssertNil(Insight.parse(storedType: "record"))
    }

    func test_merge_noDuplicateIdPerRide_updatesKeepShown() {
        var old = make(.q4After, time: 60)
        old.shownAt = now + 5
        old.createdAt = now - 10
        let new = make(.q4After, time: 90, at: now + 100)
        let m = InsightDedupe.merge(candidates: [new, new, make(.q15After, time: 60)], existing: [old], nowMs: now + 100, summarySeen: false)
        XCTAssertEqual(m.update.count, 1)
        XCTAssertEqual(m.update.first?.shownAt, now + 5)
        XCTAssertEqual(m.update.first?.createdAt, now - 10)
        XCTAssertEqual(m.update.first?.timeS, 90)
        XCTAssertEqual(m.insert.map(\.type), [.q15After])
        XCTAssertEqual(m.dropped, ["q4After:r1"], "the second copy of the same id")
    }

    func test_merge_dismissedAndOnceOnlyStayGone() {
        var gone = make(.q4After)
        gone.dismissedAt = now
        let climb = make(.q17New, ride: "r1", subject: "c1")
        let m = InsightDedupe.merge(candidates: [make(.q4After), make(.q17New, ride: "r2", subject: "c1")], existing: [gone, climb],
                                    nowMs: now, summarySeen: false)
        XCTAssertEqual(m.insert, [])
        XCTAssertEqual(m.update, [])
        XCTAssertEqual(Set(m.dropped), ["q4After:r1", "q17New:c1"])
    }

    func test_merge_cooldownPerSubject() {
        let earlier = make(.q18, ride: "r1", time: 60, at: now - 13 * day)
        let again = make(.q18, ride: "r2", time: 60)
        XCTAssertEqual(InsightDedupe.merge(candidates: [again], existing: [earlier], nowMs: now, summarySeen: false).insert, [])
        let older = make(.q18, ride: "r1", time: 60, at: now - 14 * day)
        XCTAssertEqual(InsightDedupe.merge(candidates: [again], existing: [older], nowMs: now, summarySeen: false).insert.map(\.id), ["q18:r2"])
        // another route is another subject
        var other = again
        other.subject = "B"
        XCTAssertEqual(InsightDedupe.merge(candidates: [other], existing: [earlier], nowMs: now, summarySeen: false).insert.count, 1)
    }

    func test_weatherArrives_seenSummary_goesToRecentOnly() {
        let late = make(.q15After, time: 70, at: now + 3_600_000)
        let m = InsightDedupe.merge(candidates: [late], existing: [make(.q1After, time: 60)], nowMs: now + 3_600_000, summarySeen: true)
        XCTAssertEqual(m.insert.first?.moment, .recentOnly)
        let rows = m.insert + [make(.q1After, time: 60)]
        XCTAssertEqual(InsightRanking.rank(rows, recentTopTypes: [], nowMs: now + 3_600_000).top?.type, .q1After)
        XCTAssertFalse(InsightRanking.rank(rows, recentTopTypes: [], nowMs: now + 3_600_000).more.contains { $0.type == .q15After })
        XCTAssertEqual(InsightRanking.recent(rows).first?.type, .q15After)
        // not seen yet: a normal after-ride card
        XCTAssertEqual(InsightDedupe.merge(candidates: [late], existing: [], nowMs: now, summarySeen: false).insert.first?.moment, .after)
    }

    func test_recent_lastTenByTime_notScore() {
        var rows: [Insight] = (0..<12).map { make(.q15After, ride: "r\($0)", time: 60, at: now + Int64($0) * 1_000) }
        rows.append(make(.q9Live, ride: "r99", at: now + 50_000))              // a start moment: not history
        rows.append(make(.q4After, ride: "r98", progress: true, at: now + 60_000))
        rows.append(make(.q9Live, ride: "r97", at: now - 1))
        let recent = InsightRanking.recent(rows)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.rideId, "r11")
        XCTAssertEqual(recent.last?.rideId, "r2")
        XCTAssertFalse(recent.contains { $0.isProgress || $0.moment == .start })
    }

    func test_placementsAndMoments() {
        XCTAssertEqual(InsightType.q22Weekly.placements, [.weekly, .notification])
        XCTAssertEqual(InsightType.q4After.placements, [.rideDetail, .home])
        XCTAssertEqual(InsightType.q15Notify.placements, [.notification])
        XCTAssertEqual(InsightType.q1Live.placements, [.liveBanner])
        for t in InsightType.allCases where t.moment == .start {
            XCTAssertNotNil(t.livePriority, "\(t) needs a C24 priority")
        }
    }
}
