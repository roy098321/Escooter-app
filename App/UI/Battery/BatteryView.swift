import CorckieCore
import SwiftUI

/// M3-04: the Battery page (from the Scooter tab's Battery row and from Home). Calibration status, real range (M25),
/// charge time (M37), charge log (M30), cycles (M31) and health (M32). Shown numbers are honest; the 10% safety margin is
/// only in the one row that says so.
struct BatteryView: View {
    /// Preview data for the ui-shots (no database, no Bluetooth).
    struct Preview {
        var overview: BatteryOverview
    }

    var preview: Preview?
    @State private var loaded: BatteryOverview?
    private let link = AppModel.shared.scooter

    private var overview: BatteryOverview? { preview?.overview ?? loaded }

    var body: some View {
        List {
            if let o = overview {
                nowSection(o)
                chargingSection(o)
                calibrationSection(o.calibration)
                chargeLogSection(o)
                healthSection(o)
            } else {
                Section { Text("Battery data is not available yet.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Battery")
        .onAppear(perform: reload)
        .screen("Battery")
    }

    // MARK: Sections

    @ViewBuilder private func nowSection(_ o: BatteryOverview) -> some View {
        Section {
            LabeledContent("Battery", value: Self.batteryText(o.currentPct, live: o.connected))
            if let r = o.range {
                Text(r.text).font(.subheadline)
                LabeledContent("Reserve kept", value: "\(Int(o.reservePct.rounded()))%")
                LabeledContent("With the 10% safety margin", value: (r.lowBattery ? "~" : "") + RealRangeCalc.kmText(r.decisionRangeKm))
            } else if o.currentPct == nil {
                Text("The range appears once the scooter has been seen.").foregroundStyle(.secondary)
            } else {
                Text("The range appears after your first ride (it uses how much battery a kilometre costs you).").foregroundStyle(.secondary)
            }
        } header: {
            Text("Range")
        } footer: {
            Text("The range above is the honest number. The safety margin line is what the app uses when it decides something for you.")
        }
    }

    @ViewBuilder private func chargingSection(_ o: BatteryOverview) -> some View {
        Section {
            if let h = o.chargeHours {
                LabeledContent("Full from now", value: ChargeTime.text(hours: h))
            } else if let s = o.sinceLastRide {
                LabeledContent("Full if charged from the last ride (\(Int(s.endPct.rounded()))%)", value: Self.timeText(s.fullAtMs))
            } else {
                Text("Shown while the scooter is connected. It switches off while it charges.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Charging")
        } footer: {
            Text("About 2 A: steady up to 85%, then about an hour for the rest.")
        }
    }

    @ViewBuilder private func calibrationSection(_ cal: BatteryCalibration) -> some View {
        Section {
            LabeledContent("Status", value: BatteryText.calibrationStatus(cal))
            LabeledContent("Energy", value: BatteryText.calibrationValue(cal))
            if cal.checkSuggested {
                Label("Check battery calibration", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text("Learned from your own rides: the energy the scooter reports divided by how much the battery % dropped. It starts from the 16 Ah pack and is calibrated after 5 good rides.")
        }
    }

    @ViewBuilder private func chargeLogSection(_ o: BatteryOverview) -> some View {
        Section {
            if o.charges.isEmpty {
                Text("No charge seen yet. A charge shows here after the first ride that follows it.").foregroundStyle(.secondary)
            }
            ForEach(o.charges, id: \.id) { c in
                Text(BatteryText.chargeLine(fromPct: c.fromPct ?? 0, toPct: c.toPct ?? 0, away: c.inferredWhileAway,
                                            start: Self.dayText(c.windowStartAt), end: Self.dayText(c.windowEndAt)))
                    .font(.subheadline)
            }
        } header: {
            Text("Charge log")
        } footer: {
            Text("The scooter switches off while charging, so a charge is found when the battery % is higher at the next ride than where the last ride ended.")
        }
    }

    @ViewBuilder private func healthSection(_ o: BatteryOverview) -> some View {
        Section {
            LabeledContent("Charge cycles", value: BatteryText.cyclesText(o.cycles))
            LabeledContent("Health", value: BatteryText.healthTitle(o.health))
            Text(BatteryText.healthDetail(o.health)).font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Cycles and health")
        }
    }

    // MARK: Words

    static func batteryText(_ pct: Double?, live: Bool) -> String {
        guard let pct else { return "Unknown" }
        let n = Int(pct.rounded())
        return live ? "\(n) %" : "\(n) % (when last seen)"
    }

    static func dayText(_ ms: Int64?) -> String {
        guard let ms else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func timeText(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    private func reload() {
        guard preview == nil, let db = AppModel.shared.database else { return }
        let connected = link.connected
        let live: Double? = link.frame?.batteryPct.map { Double($0) }
        let pct: Double? = connected ? live : LastSeen.load().pct.map { Double($0) }
        loaded = BatteryOverview.load(db, currentPct: pct, connected: connected)
    }
}

/// ui-shots: battery-page (learning, charges, range), battery-page-empty (new install), battery-page-calibrated (health).
enum BatteryPreview {
    private static func charge(_ id: String, _ from: Double, _ to: Double, _ at: Int64, away: Bool) -> ChargeRecord {
        ChargeRecord(id: id, scooterId: nil, afterRideId: nil, beforeRideId: nil, fromPct: from, toPct: to, fromV: nil, toV: nil,
                     windowStartAt: at, windowEndAt: at + 14 * 3_600_000, inferredWhileAway: away, startedByShutdownFlag: false)
    }

    private static func range(_ pct: Double, _ perKm: Double) -> RealRange {
        RealRange(currentPct: pct, reservePct: 5, pctPerKm: perKm, basedOnRides: 10, fromEnergy: false, lowBattery: pct < 20,
                  rangeKm: (pct - 5) / perKm, decisionRangeKm: (pct - 5) / SafetyMargin.forDecision(perKm))
    }

    static func make(_ name: String) -> BatteryView.Preview? {
        let day: Int64 = 86_400_000
        let t: Int64 = 1_790_000_000_000
        switch name {
        case "battery-page":
            let cal = BatteryCalibration(packAh: 16, whPerPct: 8.27, measuredWhPerPct: 8.35, ridesUsed: 3, status: .learning)
            return .init(overview: BatteryOverview(
                calibration: cal, charges: [charge("c2", 31, 100, t + 4 * day, away: false), charge("c1", 23, 98, t, away: true)], cycles: 3.4,
                health: .gathering(cycles: 3.4, rides: 9), currentPct: 64, connected: true, range: range(64, 2.3), reservePct: 5,
                chargeHours: ChargeTime.hoursToFull(fromPct: 64, packAh: 16), sinceLastRide: nil))
        case "battery-page-empty":
            return .init(overview: BatteryOverview(
                calibration: .prior(), charges: [], cycles: 0, health: .gathering(cycles: 0, rides: 0), currentPct: nil, connected: false,
                range: nil, reservePct: 5, chargeHours: nil, sinceLastRide: nil))
        case "battery-page-calibrated":
            let cal = BatteryCalibration(packAh: 16, whPerPct: 8.4, measuredWhPerPct: 8.4, ridesUsed: 12, status: .calibrated)
            return .init(overview: BatteryOverview(
                calibration: cal, charges: [charge("c1", 18, 100, t, away: false)], cycles: 28.6,
                health: .health(pct: 92, kmPer100Now: 74, kmPer100First: 80), currentPct: 18, connected: false, range: range(18, 2.6),
                reservePct: 5, chargeHours: nil, sinceLastRide: (endPct: 18, fullAtMs: t + 6 * 3_600_000)))
        default: return nil
        }
    }
}
