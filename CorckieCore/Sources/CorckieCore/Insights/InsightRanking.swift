import Foundation

// M4-03: ranking (CALC_SPEC 9.3), the ride-start pick (9.4: at most 2, C24 order), dedupe / cooldown, and Recent insights.
// score = class + size + freshness: class 100 / 80 / 60 / 40 / 30, size min(20, 5 x minutes + 3 x % battery), freshness
// -15 when the same type was the top card on one of the last 3 rides. Progress lines (pattern D) never compete: they sit
// in their own list below "N more".

public struct RankedInsights: Equatable, Sendable {
    /// The card shown on the summary / ride detail
    public var top: Insight?
    /// Behind "N more", in the order they expand
    public var more: [Insight]
    /// Pattern D lines ("2 of 3 windy rides")
    public var progress: [Insight]

    public init(top: Insight?, more: [Insight], progress: [Insight]) {
        self.top = top
        self.more = more
        self.progress = progress
    }

    /// "3 more"
    public var moreText: String? { more.isEmpty ? nil : "\(more.count) more" }
}

public enum InsightRanking {
    public static let freshnessPenalty = 15.0
    public static let maxSize = 20.0
    public static let freshnessRides = 3
    public static let recentLimit = 10

    /// min(20, 5 x minutes + 3 x % battery), on the absolute size of the difference
    public static func size(_ i: Insight) -> Double {
        min(maxSize, 5 * abs(i.timeS ?? 0) / 60 + 3 * abs(i.usedPct ?? 0))
    }

    /// `recentTopTypes` = the top card types of the last 3 rides (newest first; more are ignored)
    public static func score(_ i: Insight, recentTopTypes: [InsightType]) -> Double {
        if i.isProgress { return 0 }
        return Double(i.insightClass.rawValue) + size(i) + freshness(i.type, recentTopTypes: recentTopTypes)
    }

    /// -15 when the type was the top card on one of the last 3 rides
    public static func freshness(_ type: InsightType, recentTopTypes: [InsightType]) -> Double {
        recentTopTypes.prefix(freshnessRides).contains(type) ? -freshnessPenalty : 0
    }

    /// Top card + "N more" (by score, then class, then the catalogue order) + progress lines. Expired, dismissed and
    /// recent-only rows are left out.
    public static func rank(_ insights: [Insight], recentTopTypes: [InsightType], nowMs: Int64) -> RankedInsights {
        let live = insights.filter { !$0.isExpired(at: nowMs) && $0.dismissedAt == nil && $0.moment != .recentOnly }
        let order = InsightType.allCases
        // `score` holds the plain score (class + size, made with the row and stored); freshness is added here
        var scored = live.filter { !$0.isProgress }.map { i -> Insight in
            var x = i
            x.score = i.score + freshness(i.type, recentTopTypes: recentTopTypes)
            return x
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.insightClass != b.insightClass { return a.insightClass > b.insightClass }
            let ia = order.firstIndex(of: a.type) ?? 0, ib = order.firstIndex(of: b.type) ?? 0
            return ia != ib ? ia < ib : a.id < b.id
        }
        let progress = live.filter(\.isProgress).sorted { a, b in
            let ia = order.firstIndex(of: a.type) ?? 0, ib = order.firstIndex(of: b.type) ?? 0
            return ia != ib ? ia < ib : a.id < b.id
        }
        return RankedInsights(top: scored.first, more: Array(scored.dropFirst()), progress: progress)
    }

    /// Ride start (9.4, T98): at most 2 messages, in C24 priority order (then score); the rest go to the ride summary.
    public static func startPick(_ candidates: [Insight]) -> (shown: [Insight], toSummary: [Insight]) {
        let start = candidates.filter { !$0.isProgress && $0.livePriority != nil }
        let sorted = start.sorted { a, b in
            let pa = a.livePriority!, pb = b.livePriority!
            if pa != pb { return pa < pb }
            return a.score > b.score
        }
        let n = BannerQueue.maxAtRideStart
        return (Array(sorted.prefix(n)), Array(sorted.dropFirst(n)))
    }

    /// Recent insights (Stats): the last 10 by time, not by score; after-ride, weekly and late (recent-only) cards, no
    /// progress lines, nothing dismissed. Start / notification rows are moments, not history.
    public static func recent(_ insights: [Insight], limit: Int = recentLimit) -> [Insight] {
        let moments: [InsightMoment] = [.after, .weekly, .recentOnly]
        let kept = insights.filter { i in !i.isProgress && i.dismissedAt == nil && moments.contains(i.moment) }
        return Array(kept.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }.prefix(limit))
    }
}

/// What to write after a run: new rows and updated rows (same id, new numbers).
public struct InsightMerge: Equatable, Sendable {
    public var insert: [Insight]
    public var update: [Insight]
    /// ids dropped (duplicate, dismissed, once-only already given, cooldown)
    public var dropped: [String]

    public init(insert: [Insight] = [], update: [Insight] = [], dropped: [String] = []) {
        self.insert = insert
        self.update = update
        self.dropped = dropped
    }
}

public enum InsightDedupe {
    /// - same id twice in one run: the first wins (no duplicate id per ride);
    /// - id already stored: dismissed → dropped; made for the same ride / week → updated (text, numbers), keeping its
    ///   moment, createdAt and shownAt; else (a once-only row from another ride) dropped;
    /// - cooldown: a row of the same type and subject within its cooldown days (another ride) → dropped;
    /// - `summarySeen` (the ride's summary was already shown, weather arrived late): a new after-ride card is recent-only.
    public static func merge(candidates: [Insight], existing: [Insight], nowMs: Int64, summarySeen: Bool) -> InsightMerge {
        var out = InsightMerge()
        var seen = Set<String>()
        let byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in candidates {
            guard seen.insert(c.id).inserted else {
                out.dropped.append(c.id)
                continue
            }
            if let old = byId[c.id] {
                if old.dismissedAt != nil || old.rideId != c.rideId || old.weekStart != c.weekStart {
                    out.dropped.append(c.id)
                    continue
                }
                var u = c
                u.moment = old.moment
                u.createdAt = old.createdAt
                u.expiresAt = old.expiresAt
                u.shownAt = old.shownAt
                out.update.append(u)
                continue
            }
            let cool = c.type.cooldownDays
            if cool > 0, !c.isProgress, existing.contains(where: { e in
                e.type == c.type && e.subject == c.subject && !e.isProgress && e.rideId != c.rideId
                    && Double(nowMs - e.createdAt) < cool * Double(OutsideTime.dayMs)
            }) {
                out.dropped.append(c.id)
                continue
            }
            var n = c
            if summarySeen, n.moment == .after { n.moment = .recentOnly }
            out.insert.append(n)
        }
        return out
    }
}
