import CorckieCore
import GRDB
import SwiftUI

/// Hotfix 03 proof: Developer → Voice replay. Runs the new voice over this phone's newest rides on saved routes (the route's other rides
/// are the history; today's estimate as it was at that ride's start) and shows what it would have said, with the numbers, and whether
/// each ride passes: no contradictions, at most 2 battery lines, the last one within 5 points of the real arrival %, no late line before
/// the gate. Read only: nothing is written.
struct V09ReplayView: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let result: V09Replay.Result
        let utcOffsetMin: Int
    }

    @State private var rows: [Item]?

    var body: some View {
        List {
            if let rows {
                Section {
                    let passed = rows.filter(\.result.passed).count
                    Text(rows.isEmpty ? "No rides on a saved route yet." : "\(passed) of \(rows.count) rides pass")
                        .font(.headline)
                        .foregroundStyle(rows.isEmpty || passed == rows.count ? Color.green : Color.red)
                } footer: {
                    Text("Pass: never a higher number after a lower one, at most 2 battery lines, the last within 5 points of the real arrival, no late line before 3 km and a third of the route.")
                }
                ForEach(rows) { row in
                    Section(row.title) {
                        Label(row.result.passed ? "Pass" : row.result.problems.joined(separator: " \u{00B7} "),
                              systemImage: row.result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(row.result.passed ? Color.green : Color.red)
                        if row.result.said.isEmpty { Text("Said nothing").foregroundStyle(.secondary) }
                        ForEach(Array(row.result.said.enumerated()), id: \.offset) { _, s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.line).font(.subheadline)
                                Text(Self.numbers(s.numbers)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text(Self.real(row)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Replaying your newest rides\u{2026}")
            }
        }
        .navigationTitle("Voice replay")
        .navigationBarTitleDisplayMode(.inline)
        .task { if rows == nil { rows = Self.load() } }
        .screen("Voice replay")
    }

    static func numbers(_ n: V09Numbers) -> String {
        func f(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "\u{2013}" }
        var parts = ["km \(f(n.alongKm))", "level \(f(n.levelPct))%", "scooter \(f(n.livePct))%"]
        if let a = n.arrivalPct { parts.append("arrival \(f(a))%" + (n.stable ? " steady" : "")) }
        if let l = n.lateS { parts.append("late \(Int((l / 60).rounded())) min") }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func real(_ row: Item) -> String {
        var parts: [String] = []
        if let p = row.result.realArrivalPct { parts.append("Real arrival \(Int(p.rounded()))%") }
        if let t = row.result.realArrivalS { parts.append("at \(V09Message.clock(epochS: t, utcOffsetMin: row.utcOffsetMin))") }
        return parts.isEmpty ? "No real arrival (the ride did not reach the end of the route)" : parts.joined(separator: " ")
    }

    /// The newest rides on saved routes (at most `limit`)
    static func load(limit: Int = 6) -> [Item] {
        guard let db = AppModel.shared.database else { return [] }
        let rides = (try? db.writer.read { d in
            try GRDB.Row.fetchAll(d, sql: """
                SELECT id, routeId, startAt, utcOffsetMin FROM ride
                WHERE routeId IS NOT NULL AND kind = 'ride' AND isSimulated = 0 ORDER BY startAt DESC LIMIT ?
                """, arguments: [limit])
        }) ?? []
        let wh = CalibrationUpdater.current(db).whPerPct
        var out: [Item] = []
        for r in rides {
            let id: String = r["id"]
            let routeId: String = r["routeId"]
            let startAt: Int64 = r["startAt"]
            let offset: Int = r["utcOffsetMin"] ?? RouteCardLoader.currentOffsetMin()
            guard var f = RouteFollowLoader.follower(routeId: routeId, database: db, nowMs: startAt, utcOffsetMin: offset) else { continue }
            f.history = RouteFollowLoader.history(routeId: routeId, follower: f, database: db, excludingRideId: id)
            let result = V09Replay.run(samples: RouteFollowLoader.historySamples(rideId: id, database: db), route: f, whPerPct: wh,
                                       usualPctPerKm: RouteFollowLoader.usualPctPerKm(routeId: routeId, database: db),
                                       placeName: f.destinationName, utcOffsetMin: offset)
            let date = Date(timeIntervalSince1970: Double(startAt) / 1000).formatted(date: .abbreviated, time: .shortened)
            out.append(Item(id: id, title: "\(f.destinationName) \u{00B7} \(date)", result: result, utcOffsetMin: offset))
        }
        return out
    }
}

