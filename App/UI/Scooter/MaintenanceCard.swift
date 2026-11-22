import CorckieCore
import SwiftUI

/// N10-21 (batch 10, owner 20 Nov, option A + battery tile idea 1; mock new-scooter-and-battery.png): under the hero a Maintenance
/// card. Battery is a WIDE tile on its own row ("≈ 21 km · health 94%", orange ›) and opens the one Battery page; Brakes, Tyres,
/// Motor, Electrics, Bolts are smaller tiles in one row below; a tile with an issue lights orange with "!"; one line below says
/// what is due. The header row opens the Maintenance screen, a tile opens that part.
struct MaintenanceCard: View {
    let rows: [PartRow]
    /// "≈ 21 km · health 94%" (nil until known)
    let batteryLine: String?

    private static let small: [MaintPart] = [.brakes, .tyres, .motor, .electrics, .bolts]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink { MaintenanceView() } label: {
                HStack {
                    Label("Maintenance", systemImage: "wrench.adjustable").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink { BatteryView() } label: { batteryTile }
                .buttonStyle(.plain)
            HStack(spacing: 8) {
                ForEach(Self.small, id: \.self) { p in
                    NavigationLink { PartPageView(part: p) } label: { tile(p) }   // option A: the part's own page, one screen
                        .buttonStyle(.plain)
                }
            }
            if let line = MaintParts.homeLine(rows) {
                Text(line)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentInk)
            }
        }
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
    }

    private func row(_ p: MaintPart) -> PartRow? { rows.first { $0.part == p } }

    private var batteryTile: some View {
        let r = row(.battery)
        let alert = r?.standsOut == true
        return HStack(spacing: 12) {
            Image(systemName: PartIcon.symbol(.battery))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 44, height: 44)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Battery").font(.body.weight(.semibold))
                if let line = alert ? r?.line : batteryLine {
                    Text(line).font(.subheadline).foregroundStyle(alert ? Theme.accentInk : .secondary)
                }
            }
            Spacer(minLength: 4)
            if alert { badge }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
        }
        .padding(10)
        .background(alert ? Theme.accent.opacity(0.18) : Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent, lineWidth: alert ? 2 : 1))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the Battery page")
    }

    private func tile(_ p: MaintPart) -> some View {
        let alert = row(p)?.standsOut == true
        return VStack(spacing: 6) {
            Image(systemName: PartIcon.symbol(p))
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(p.title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(alert ? Theme.accent.opacity(0.18) : Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent, lineWidth: alert ? 2 : 0))
        .overlay(alignment: .topTrailing) { if alert { badge.offset(x: 6, y: -6) } }
        .accessibilityElement(children: .combine)
        .accessibilityValue(alert ? "Needs attention" : "")
    }

    private var badge: some View {
        Text("!")
            .font(.caption.weight(.heavy))
            .frame(width: 20, height: 20)
            .background(Theme.accent, in: Circle())
            .foregroundStyle(.black.opacity(0.85))
            .accessibilityHidden(true)
    }
}

/// N10-21 merge: the Battery page's Maintenance part, on top, only when there is something: open battery findings (F1, F11, F12)
/// with "Checked, it's fine" and Details, then the next battery check
struct BatteryFaultsSection: View {
    @State private var open: [FaultRecord] = []
    @State private var detail: FaultRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(open) { r in
                let t = FaultCopy.text(r.kind)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: PartIcon.symbol(.battery))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 44, height: 44)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Needs a look").font(.subheadline).foregroundStyle(Theme.accentInk)
                            Text(t.row).font(.headline)
                        }
                    }
                    Text(t.found).font(.subheadline)
                    HStack {
                        Button(FaultCopy.checkedFine) {
                            FaultStore.checkedFine(r.id, AppModel.shared.database)
                            reload()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Details") { detail = r }
                            .foregroundStyle(Theme.accentInk)
                    }
                }
                .padding(DS.Space.cardPad)
                .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(Theme.accent, lineWidth: 2))
            }
        }
        .sheet(item: $detail, onDismiss: reload) { r in FaultDetailSheet(record: r, onDone: reload) }
        .onAppear(perform: reload)
    }

    private func reload() {
        guard let db = AppModel.shared.database else { return }
        open = FaultRecord.open(FaultStore.records(db), scooterId: MaintenanceService.scooterId(db)).filter { $0.kind.part == .battery }
    }
}
