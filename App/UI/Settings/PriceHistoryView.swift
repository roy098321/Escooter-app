import CorckieCore
import SwiftUI

/// F-01: Settings → Costs → Price history. Fuel price and electricity rate as value + "valid from" date. A new price only applies from its
/// date on, so past savings never change. Adding a price with the date of an existing row replaces that row (that is how a typo is fixed).
struct PriceHistoryView: View {
    @State private var fuel: [PriceRow] = []
    @State private var electricity: [PriceRow] = []
    @State private var fuelValue = ""
    @State private var electricityValue = ""
    @State private var fuelDate = Date()
    @State private var electricityDate = Date()

    private var db: AppDatabase? { AppModel.shared.displayDatabase }

    var body: some View {
        Form {
            section(title: "Fuel price (\u{20AA} per litre)", rows: fuel, value: $fuelValue, date: $fuelDate, kind: PriceHistoryQueries.fuel,
                    info: InfoContent(lead: "A new price counts from its date on.", basedOn: [InfoBasedOn("Fuel", "95 octane, self-service")]))
            section(title: "Electricity rate (\u{20AA} per kWh)", rows: electricity, value: $electricityValue, date: $electricityDate,
                    kind: PriceHistoryQueries.electricity, info: InfoContent(lead: "A new rate counts from its date on."))
        }
        .glassList()
        .navigationTitle("Price history")
        .hidesTabBar()                  // B28: the Add row and the keyboard must not meet the tab bar
        .screen("Price history")
        .onAppear(perform: load)
    }

    private func section(title: String, rows: [PriceRow], value: Binding<String>, date: Binding<Date>, kind: String, info: InfoContent) -> some View {
        Section {
            ForEach(rows.reversed(), id: \.validFrom) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.2f \u{20AA}", row.value)).font(.body)
                        Text(row.unverified ? "from \(Self.label(row.validFrom)) \u{00B7} unverified, please check" : "from \(Self.label(row.validFrom))")
                            .font(.footnote).foregroundStyle(row.unverified ? Color.orange : Color.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { remove(row) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete this price")
                }
            }
            HStack {
                TextField("New price", text: value).keyboardType(.decimalPad)
                DatePicker("From", selection: date, displayedComponents: .date).labelsHidden()
                Button("Add") { add(kind: kind, value: value, date: date) }
                    .disabled(Double(value.wrappedValue.replacingOccurrences(of: ",", with: ".")) == nil)
            }
        } header: {
            HStack(spacing: 4) {
                Text(title).textCase(nil)
                InfoButton(title, info: info)
            }
        }
        .glassRows()
    }

    static func label(_ day: String) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]) else { return day }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(p[2]) \(names[p[1] - 1]) \(p[0])"
    }

    static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    private func load() {
        guard let db else { return }
        let q = PriceHistoryQueries(db)
        fuel = (try? q.rows(kind: PriceHistoryQueries.fuel)) ?? []
        electricity = (try? q.rows(kind: PriceHistoryQueries.electricity)) ?? []
    }

    private func add(kind: String, value: Binding<String>, date: Binding<Date>) {
        guard let db = AppModel.shared.database, !db.isReadOnly,
              let v = Double(value.wrappedValue.replacingOccurrences(of: ",", with: ".")), v > 0, v < 50 else { return }
        let q = PriceHistoryQueries(db)
        let day = Self.dayString(date.wrappedValue)
        if kind == PriceHistoryQueries.electricity {
            let old = StatsQueries(db).number(StatsQueries.electricityKey) ?? StatsPrices.defaultElectricityIlsPerKwh
            try? q.setElectricity(v, from: day, currentDefault: old)
            // the "current" rate setting follows the newest row that has already started
            let today = Self.dayString(Date())
            if day <= today { try? StatsQueries(db).setNumber(StatsQueries.electricityKey, v) }
        } else {
            try? q.set(PriceRow(kind: kind, validFrom: day, value: v, source: "manual", unverified: false))
        }
        value.wrappedValue = ""
        load()
    }

    private func remove(_ row: PriceRow) {
        guard let db = AppModel.shared.database, !db.isReadOnly else { return }
        try? PriceHistoryQueries(db).remove(kind: row.kind, validFrom: row.validFrom)
        load()
    }
}

/// F-01: purchase date and the odometer at purchase (default 0 = the scooter was new). Used to estimate the km before CorckieApp.
struct PurchaseSettingsView: View {
    @State private var date = Date()
    @State private var odometer = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                DatePicker("Purchase date", selection: $date, displayedComponents: .date)
                HStack {
                    Text("Odometer at purchase")
                    Spacer()
                    TextField("0", text: $odometer)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("km").foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Before CorckieApp").textCase(nil)
                    InfoButton("Before the app", info: InfoContent(lead: "Overall stats estimate the km ridden before the first logged ride.", formula: [], basedOn: [InfoBasedOn("Estimate", "odometer at the first ride minus odometer at purchase")], caveat: "Use 0 for a new scooter."))
                }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Purchase")
        .hidesTabBar()
        .screen("Purchase")
        .onAppear {
            let db = AppModel.shared.displayDatabase
            let parts = OverallSettings.purchaseDay(db).split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let d = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) { date = d }
            let odo = OverallSettings.odometerAtPurchase(db)
            odometer = odo == 0 ? "" : String(odo)
            DispatchQueue.main.async { loaded = true }
        }
        .onChange(of: date) { _, d in
            guard loaded else { return }
            SettingsValue.set(AppModel.shared.database, OverallSettings.purchaseDayKey, PriceHistoryView.dayString(d))
        }
        .onChange(of: odometer) { _, text in
            guard loaded else { return }
            let v = text.isEmpty ? 0 : Double(text.replacingOccurrences(of: ",", with: "."))
            if let v, v >= 0, v < 100_000 { SettingsValue.set(AppModel.shared.database, OverallSettings.purchaseOdoKey, String(v)) }
        }
    }
}
