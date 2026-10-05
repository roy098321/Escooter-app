import CorckieCore
import Foundation

// M4-05: the smart prompt (C26) and the Loaded tag on the stored rides. Rules: Core `SmartPrompt` (unit tested). Here: the ride's numbers
// from the database, the once-a-day / pause state in `setting`, the answers applied to the ride (load, "not typical", tyre reminder),
// and the re-run of the factors and the insights after an answer (the effects change when the load or the usual range does).
// Compiled into AppTests with App/Store and App/Routes.

enum SmartPromptService {
    private static func int(_ db: AppDatabase, _ key: String) -> Int64? {
        guard let s = try? RideQueries(db).setting(key: key) else { return nil }
        return Int64(s)
    }

    private static func string(_ db: AppDatabase, _ key: String) -> String? {
        (try? RideQueries(db).setting(key: key)) ?? nil
    }

    private static func put(_ db: AppDatabase, _ key: String, _ value: String) {
        try? RideQueries(db).setSetting(key: key, json: value)
    }

    static func state(_ db: AppDatabase) -> SmartPromptState {
        SmartPromptState(lastShownDay: int(db, "prompt.lastDay"), lastShownRideId: string(db, "prompt.lastRide"),
                         dismissStreak: Int(int(db, "prompt.streak") ?? 0), pausedUntilMs: int(db, "prompt.pausedUntil"))
    }

    private static func save(_ db: AppDatabase, _ s: SmartPromptState) {
        put(db, "prompt.lastDay", s.lastShownDay.map(String.init) ?? "")
        put(db, "prompt.lastRide", s.lastShownRideId ?? "")
        put(db, "prompt.streak", String(s.dismissStreak))
        put(db, "prompt.pausedUntil", s.pausedUntilMs.map(String.init) ?? "")
    }

    /// Answered or dismissed rides never ask again
    private static func done(_ db: AppDatabase, _ rideId: String) -> Bool { string(db, "prompt.done.\(rideId)") != nil }

    /// The card for a ride, or nil (the ride's summary calls this when it opens)
    static func card(_ db: AppDatabase, rideId: String, nowMs: Int64 = FactorUpdater.nowMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) -> SmartPromptCard? {
        guard let ride = try? InsightQueries(db).ride(rideId), ride.endAt != nil, ride.kind == "ride",
              let routeId = ride.routeId, let route = try? RouteQueries(db).route(id: routeId), route.state == "saved" else { return nil }
        let rows = ((try? RouteQueries(db).routeRides(routeId: routeId)) ?? []).filter { $0.kind == "ride" }
        let others = UsualRange.select(RouteCardLoader.stats(rows).filter { $0.rideId != rideId }, nowMs: nowMs)
        let answered = done(db, rideId) || ((try? SmartPromptQueries(db).rideAnswer(rideId))?.promptAnswer != nil)
        return SmartPrompt.card(rideId: rideId, routeRides: others.count, usedPct: ride.usedPct,
                                usualUsed: UsualRange.range(of: .battery, rides: others),
                                explanation: FactorEffects.forRide(db, rideId: rideId, nowMs: nowMs), alreadyAnswered: answered,
                                state: state(db), nowMs: nowMs, utcOffsetMin: utcOffsetMin)
    }

    /// The card went on screen: it counts for today (once a day)
    static func shown(_ db: AppDatabase, rideId: String, nowMs: Int64 = FactorUpdater.nowMs(), utcOffsetMin: Int = RouteCardLoader.currentOffsetMin()) {
        save(db, SmartPrompt.afterShown(state(db), rideId: rideId, nowMs: nowMs, utcOffsetMin: utcOffsetMin))
    }

    /// An answer: applied to the ride, counted, the factors and insights run again
    static func answer(_ db: AppDatabase, rideId: String, _ answer: SmartAnswer, nowMs: Int64 = FactorUpdater.nowMs()) throws {
        let q = SmartPromptQueries(db)
        if let level = answer.loadLevel, let kg = level.presetKg {
            try q.setLoad(rideId: rideId, level: level.rawValue, kg: kg)
        }
        try q.setAnswer(rideId: rideId, answer: answer.rawValue, excluded: answer.excludesFromUsual)
        if answer.makesTyresDue {
            try q.makeTyresDue(odometerKm: try MaintenanceQueries(db).odometerKm(), nowMs: nowMs)
        }
        put(db, "prompt.count.\(answer.rawValue)", String(answerCount(db, answer) + 1))
        put(db, "prompt.done.\(rideId)", answer.rawValue)
        save(db, SmartPrompt.afterAnswer(state(db)))
        try rerun(db, rideId: rideId, nowMs: nowMs)
    }

    /// Closed without an answer: 2 in a row pause the card for 7 days
    static func dismiss(_ db: AppDatabase, rideId: String, nowMs: Int64 = FactorUpdater.nowMs()) {
        put(db, "prompt.done.\(rideId)", "dismissed")
        save(db, SmartPrompt.afterDismiss(state(db), nowMs: nowMs))
    }

    /// How many times an answer was given (3 or more: a row on the Factors page, e.g. "Soft tyres")
    static func answerCount(_ db: AppDatabase, _ answer: SmartAnswer) -> Int {
        Int(int(db, "prompt.count.\(answer.rawValue)") ?? 0)
    }

    // MARK: Loaded tag

    /// The Loaded tag on a ride (None 0 / Light 5 / Heavy 15 kg, or an exact number); the load effect is worked out again
    static func setLoad(_ db: AppDatabase, rideId: String, level: LoadLevel, kg: Double? = nil, nowMs: Int64 = FactorUpdater.nowMs()) throws {
        guard let value = kg ?? level.presetKg, value >= 0, value <= 100 else { return }
        try SmartPromptQueries(db).setLoad(rideId: rideId, level: level.rawValue, kg: value)
        try rerun(db, rideId: rideId, nowMs: nowMs)
    }

    private static func rerun(_ db: AppDatabase, rideId: String, nowMs: Int64) throws {
        try FactorUpdater.update(db, rideId: rideId, nowMs: nowMs)
        try InsightRunner.afterRide(db, rideId: rideId, nowMs: nowMs)
    }
}
