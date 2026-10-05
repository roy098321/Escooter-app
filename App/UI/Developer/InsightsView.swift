import CorckieCore
import SwiftUI

/// Developer → Insights (M4-03, checks u32 / mi1): the "simulated windy week" (M4_PLAN section 6) in a temporary database:
/// made-up rides in the ocean on a saved route, their weather, factors and insights, exactly as after a real ride; then
/// deleted. Below the gate (4 rides) shows the progress line, above it (24 rides) the after-ride card. Plus this phone's
/// Recent insights (the last 10 by time).
struct InsightsView: View {
    struct Line: Identifiable {
        let id = UUID()
        let label: String
        let text: String
    }

    @State private var title = ""
    @State private var lines: [Line] = []
    @State private var recent: [Line] = InsightsView.phoneRecent()

    var body: some View {
        List {
            Section {
                Button("Simulated windy week · 4 rides (below the gate)") { run(rides: 4) }
                Button("Simulated windy week · 24 rides (above the gate)") { run(rides: 24) }
                Button("Simulated hot ride (heat cards)") { runHot() }
                Button("Simulated smart prompt ride") { runPrompt() }
            } footer: {
                Text("Made-up rides in the ocean in a temporary database, deleted right after. Your real rides are not touched.")
            }
            if !lines.isEmpty {
                Section(title) {
                    ForEach(lines) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.label).font(.caption).foregroundStyle(.secondary)
                            Text(l.text)
                        }
                    }
                }
            }
            Section("This phone · Recent insights") {
                if recent.isEmpty {
                    Text("No insights yet").foregroundStyle(.secondary)
                }
                ForEach(recent) { l in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.label).font(.caption).foregroundStyle(.secondary)
                        Text(l.text)
                    }
                }
            }
        }
        .navigationTitle("Insights")
        .screen("Insights")
    }

    private func run(rides: Int) {
        var out: [Line] = []
        do {
            let db = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { db.discardTemporary() }
            let r = try InsightSeed.windyWeek(db, rides: rides)
            let store = InsightQueries(db)
            let ranked = try store.ranked(forRide: r.lastRideId, nowMs: r.nowMs)
            if let top = ranked.top { out.append(Line(label: "Top card · \(top.type.rawValue) · score \(Int(top.score))", text: top.text)) }
            if let more = ranked.moreText { out.append(Line(label: "Behind \"\(more)\"", text: ranked.more.map(\.text).joined(separator: "\n"))) }
            for p in ranked.progress { out.append(Line(label: "Progress line (pattern D) · \(p.type.rawValue)", text: p.text)) }
            let ws = InsightWeek.start(ms: r.nowMs, utcOffsetMin: FactorSeed.utcOffsetMin)
            for w in try store.weekCard(weekStart: ws - 7 * OutsideTime.dayMs) + store.weekCard(weekStart: ws) {
                out.append(Line(label: "Week card · \(w.type.rawValue)", text: w.text))
            }
            if out.isEmpty { out.append(Line(label: "Nothing", text: "No insight for the last ride")) }
            title = "\(rides) rides on \(InsightSeed.routeName) · \(r.report.text)"
        } catch {
            title = "Failed"
            out = [Line(label: "Error", text: error.localizedDescription)]
        }
        lines = out
    }

    /// M4-06 (mh1): a hot ride on a route with 11 other rides: the Peak card first, then the hot-day card
    private func runHot() {
        var out: [Line] = []
        do {
            let db = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { db.discardTemporary() }
            let r = try InsightSeed.hotRide(db)
            let ranked = try InsightQueries(db).ranked(forRide: r.lastRideId, nowMs: r.nowMs + 60_000)
            if let top = ranked.top { out.append(Line(label: "Top card · " + top.type.rawValue, text: top.text)) }
            for m in ranked.more { out.append(Line(label: "Behind " + (ranked.moreText ?? "more") + " · " + m.type.rawValue, text: m.text)) }
            title = "Hot ride on " + InsightSeed.routeName
        } catch {
            title = "Failed"
            out = [Line(label: "Error", text: error.localizedDescription)]
        }
        lines = out
    }

    /// M4-05 (mp1): a ride that used 8 points more battery than usual: the card, then what each answer does to the ride
    private func runPrompt() {
        var out: [Line] = []
        do {
            let db = try AppDatabase.openTemporary(build: AppInfo.build)
            defer { db.discardTemporary() }
            let r = try InsightSeed.promptRide(db)
            let nowMs = r.nowMs
            if let c = SmartPromptService.card(db, rideId: r.lastRideId, nowMs: nowMs, utcOffsetMin: FactorSeed.utcOffsetMin) {
                out.append(Line(label: "Prompt card", text: c.text))
                for a in c.answers {
                    try SmartPromptService.answer(db, rideId: r.lastRideId, a, nowMs: nowMs)
                    let x = try SmartPromptQueries(db).rideAnswer(r.lastRideId)
                    let loadText = LoadLevel.label(level: x?.loadLevel, kg: x?.loadKg)
                    let leftOut = x?.excluded == true ? "yes" : "no"
                    out.append(Line(label: "Answer · " + a.title, text: "load " + loadText + " · left out of usual: " + leftOut))
                }
            } else {
                out.append(Line(label: "No card", text: "The prompt gates were not met"))
            }
            title = "Smart prompt on " + InsightSeed.routeName
        } catch {
            title = "Failed"
            out = [Line(label: "Error", text: error.localizedDescription)]
        }
        lines = out
    }

    private static func phoneRecent() -> [Line] {
        guard let db = AppModel.shared.database, let rows = try? InsightQueries(db).recent() else { return [] }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return rows.map { i in
            Line(label: "\(f.string(from: Date(timeIntervalSince1970: Double(i.createdAt) / 1000))) · \(i.type.rawValue)", text: i.text)
        }
    }
}
