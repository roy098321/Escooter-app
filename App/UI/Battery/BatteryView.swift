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
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.block) {
                if let o = overview {
                    tiles(o)
                    nowSection(o)
                    chargingSection(o)
                    calibrationSection(o.calibration)
                    chargeLogSection(o)
                    healthSection(o)
                } else {
                    Text("Battery data is not available yet.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(DS.Space.cardPad).glassCard(padding: 0)
                }
            }
            .padding(DS.Space.gutter)
        }
        .background { MapBackdrop().ignoresSafeArea() }
        .navigationTitle("Battery")
        .onAppear(perform: reload)
        .screen("Battery")
    }

    /// Prototype order: three tiles first (health, cycles, to full), then the range card
    private func tiles(_ o: BatteryOverview) -> some View {
        StatTileGrid {
            StatTile(value: BatteryText.healthTitle(o.health), label: "Health")
            StatTile(value: BatteryText.cyclesText(o.cycles), label: "Charge cycles")
            StatTile(value: o.chargeHours.map { ChargeTime.text(hours: $0) } ?? "\u{2013}", label: "To full")
        }
    }

    /// One glass card with a small header and a footer line
    private func card<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.cardPad)
                .glassCard(padding: 0)
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 6)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Sections

    @ViewBuilder private func nowSection(_ o: BatteryOverview) -> some View {
        card("Range", footer: "The range above is the honest number. The safety margin line is what the app uses when it decides something for you.") {
            line("Battery", Self.batteryText(o.currentPct, live: o.connected))
            if let r = o.range {
                Text(r.text).font(.subheadline)
                line("Reserve kept", "\(Int(o.reservePct.rounded()))%")
                line("With the 10% safety margin", (r.lowBattery ? "~" : "") + RealRangeCalc.kmText(r.decisionRangeKm))
            } else if o.currentPct == nil {
                Text("The range appears once the scooter has been seen.").foregroundStyle(.secondary)
            } else {
                Text("The range appears after your first ride (it uses how much battery a kilometre costs you).").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func chargingSection(_ o: BatteryOverview) -> some View {
        card("Charging", footer: "About 2 A: steady up to 85%, then about an hour for the rest.") {
            if let h = o.chargeHours {
                line("Full from now", ChargeTime.text(hours: h))
            } else if let s = o.sinceLastRide {
                line("Full if charged from the last ride (\(Int(s.endPct.rounded()))%)", Self.timeText(s.fullAtMs))
            } else {
                Text("Shown while the scooter is connected. It switches off while it charges.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func calibrationSection(_ cal: BatteryCalibration) -> some View {
        card("Calibration", footer: "Learned from your own rides: the energy the scooter reports divided by how much the battery % dropped. It starts from the 16 Ah pack and is calibrated after 5 good rides.") {
            line("Status", BatteryText.calibrationStatus(cal))
            line("Energy", BatteryText.calibrationValue(cal))
            if cal.checkSuggested {
                Label("Check battery calibration", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func chargeLogSection(_ o: BatteryOverview) -> some View {
        card("Charge log", footer: "The scooter switches off while charging, so a charge is found when the battery % is higher at the next ride than where the last ride ended.") {
            if o.charges.isEmpty {
                Text("No charge seen yet. A charge shows here after the first ride that follows it.").foregroundStyle(.secondary)
            }
            ForEach(o.charges, id: \.id) { c in
                Text(BatteryText.chargeLine(fromPct: c.fromPct ?? 0, toPct: c.toPct ?? 0, away: c.inferredWhileAway,
                                            start: Self.dayText(c.windowStartAt), end: Self.dayText(c.windowEndAt)))
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder private func healthSection(_ o: BatteryOverview) -> some View {
        card("Cycles and health") {
            line("Charge cycles", BatteryText.cyclesText(o.cycles))
            line("Health", BatteryText.healthTitle(o.health))
            Text(BatteryText.healthDetail(o.health)).font(.footnote).foregroundStyle(.secondary)
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
