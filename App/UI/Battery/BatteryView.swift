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
                    rangeCard(o)
                    tiles(o)
                    calibrationRow(o.calibration)
                    chargeLogSection(o)
                } else {
                    emptyState("bolt.slash", "No battery data")
                }
            }
            .padding(DS.Space.gutter)
        }
        .background { MapBackdrop().ignoresSafeArea() }
        .stiffBounce()
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)   // G3
        .onAppear(perform: reload)
        .screen("Battery")
    }

    private func emptyState(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
    }

    /// B1 / B5: one big range, the safe range small beside it, the battery % with a clock when it is the last seen one
    private func rangeCard(_ o: BatteryOverview) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let r = o.range {
                    Text(RealRangeCalc.kmText(r.rangeKm))
                        .scaledFont(40, weight: .bold, mono: true, relativeTo: .largeTitle)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    InfoChip("shield", "safe " + RealRangeCalc.kmText(r.decisionRangeKm), label: "Safe range")
                } else {
                    Image(systemName: "gauge.with.needle").font(.title).foregroundStyle(.secondary)
                    Text("after a ride").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if !o.connected && o.currentPct != nil { Image(systemName: "clock").font(.footnote).foregroundStyle(.secondary) }
                Text(o.currentPct.map { "\(Int($0.rounded()))%" } ?? "\u{2013}")
                    .scaledFont(28, weight: .semibold, mono: true, relativeTo: .title)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.batteryText(o.currentPct, live: o.connected))
        }
        .padding(DS.Space.cardPad)
        .glassCard(radius: DS.Radius.hero, padding: 0)
    }

    /// B4: a tile that has nothing to show yet is not drawn
    private func tiles(_ o: BatteryOverview) -> some View {
        StatTileGrid {
            if let h = Self.healthTile(o.health) { StatTile(value: h, label: "Health") }
            StatTile(value: BatteryText.cyclesText(o.cycles), label: "Charge cycles")
            if let h = o.chargeHours {
                StatTile(value: ChargeTime.text(hours: h), label: "To full")
            } else if let s = o.sinceLastRide {
                StatTile(value: Self.timeText(s.fullAtMs), label: "Full at")
            }
        }
    }

    /// the tile shows the percentage only; nil (hidden) while it is still gathering data
    static func healthTile(_ h: BatteryHealth.State) -> String? {
        let t = BatteryText.healthTitle(h)
        return t.count <= 6 ? t : nil
    }

    /// One glass card with a small header (and an optional ⓘ)
    private func card<Content: View>(_ title: String, info: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info {
                SectionHeader(title) { InfoButton(title, text: info) }
            } else {
                SectionHeader(title)
            }
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.cardPad)
                .glassCard(padding: 0)
        }
    }

    // MARK: Sections

    /// B3: calibration is one row, the energy figures and the explanation behind the ⓘ
    @ViewBuilder private func calibrationRow(_ cal: BatteryCalibration) -> some View {
        HStack {
            Label(BatteryText.calibrationStatus(cal), systemImage: cal.checkSuggested ? "exclamationmark.triangle" : "gauge.with.dots.needle.33percent")
                .font(.subheadline)
                .foregroundStyle(cal.checkSuggested ? Theme.danger : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            InfoButton("Calibration", text: BatteryText.calibrationValue(cal) + ". Learned from your own rides: the energy the scooter reports divided by how much the battery % dropped. It is calibrated after 5 good rides.")
        }
        .padding(.leading, DS.Space.cardPad)
        .padding(.trailing, 4)
        .frame(minHeight: DS.hit)
        .glassCard(padding: 0)
    }

    @ViewBuilder private func chargeLogSection(_ o: BatteryOverview) -> some View {
        card("Charge log", info: "The scooter switches off while charging, so a charge is found when the battery % is higher at the next ride than where the last ride ended. Charge cycles are the battery used, added up, in full charges.") {
            if o.charges.isEmpty {
                Label("No charge yet", systemImage: "bolt.slash").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(o.charges, id: \.id) { c in
                Text(BatteryText.chargeLine(fromPct: c.fromPct ?? 0, toPct: c.toPct ?? 0, away: c.inferredWhileAway,
                                            start: Self.dayText(c.windowStartAt), end: Self.dayText(c.windowEndAt)))
                    .font(.subheadline)
            }
        }
    }

    // MARK: Words

    static func batteryText(_ pct: Double?, live: Bool) -> String {
        guard let pct else { return "Unknown" }
        let n = Int(pct.rounded())
        return live ? "\(n)%" : "\(n)%, last seen"
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
