import CorckieCore
import SwiftUI

/// ui-shots (made-up data only): the charging Scooter tab, the Plugged in sheet in each mode, the Home charging pill and the charge log.
enum ChargePreview {
    static let nowMs: Int64 = 1_790_000_000_000

    /// Plugged in 4 h before `nowMs` at 18 %: \u{2248} 72 % now, full in about 2 h
    static func session(_ target: ChargeTarget = .none) -> ChargeSession {
        ChargeSession(id: "preview", startPct: 18, startMs: nowMs - 4 * 3_600_000, target: target, pctPerKm: 2.3, usualNeedPct: 20, usualName: "Work", scooterName: "G2")
    }

    static let names = ["scooter-tab-charging", "charge-sheet", "charge-sheet-km", "charge-sheet-ready", "charge-sheet-correct", "home-charging", "charge-log"]

    /// F-31b: the alert sheet as it would open 8 min after the last reading (18 %)
    private static var draft: ChargeSession {
        ChargeSession(id: "preview", startPct: 18, startMs: nowMs, target: .none, pctPerKm: 2.3, usualNeedPct: 20, usualName: "Work", scooterName: "G2")
    }

    @ViewBuilder static func screen(_ name: String) -> some View {
        switch name {
        case "charge-sheet", "charge-sheet-ready", "charge-sheet-correct": sheet(PlugAlertSheet(alert: .battery(100), session: draft, utcOffsetMin: 0) { _ in })
        case "charge-sheet-km": sheet(PlugAlertSheet(alert: .range(15), session: draft, utcOffsetMin: 0) { _ in })
        case "charge-log": ScrollView { ChargeLogChartView(readings: logReadings, rows: logRows, nowMs: nowMs).padding(DS.Space.gutter) }
                .background { MapBackdrop().ignoresSafeArea() }
        default: EmptyView()
        }
    }

    private static func sheet(_ content: some View) -> some View {
        content.background(Theme.background).frame(maxHeight: .infinity, alignment: .top).background { MapBackdrop().ignoresSafeArea() }
    }

    /// Home's status pill while charging (the shot wraps it like Home's top of screen)
    static var homeLine: some View {
        VStack(spacing: 16) {
            ChargeStatusLine(session: session(), nowMs: nowMs, utcOffsetMin: 0)
            Spacer()
        }
        .padding(DS.Space.gutter)
        .background { MapBackdrop().ignoresSafeArea() }
    }

    static var logRows: [ChargeRow] {
        let h: Int64 = 3_600_000
        let n = nowMs
        return [
            ChargeRow(id: "1", startMs: n - 20 * h, endMs: n - 17 * h, startPct: 33, endPct: 65, source: .measured),
            ChargeRow(id: "2", startMs: n - 44 * h, endMs: n - 36 * h, startPct: 20, endPct: 66, source: .seen),
            ChargeRow(id: "3", startMs: n - 70 * h, endMs: n - 64 * h, startPct: 25, endPct: 78, source: .estimated),
            ChargeRow(id: "4", startMs: n - 120 * h, endMs: n - 100 * h, startPct: 40, endPct: 84, source: .away)
        ]
    }

    static var logReadings: [ChargeReading] {
        let h: Int64 = 3_600_000
        let n = nowMs
        let pts: [(Int64, Double)] = [(150, 50), (140, 38), (125, 77), (110, 31), (96, 88), (90, 80), (70, 30), (60, 70), (50, 28), (38, 86), (30, 50), (22, 33), (14, 78), (8, 52), (2, 62)]
        return pts.map { ChargeReading(ms: n - $0.0 * h, pct: $0.1) }
    }
}
