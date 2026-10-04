import Foundation
import GRDB
import SwiftUI

/// Fuel price for "fuel money saved" (M35b) · owner, P4_DILEMMAS D4 S: **manual in v1**,
/// starting at 8.27 ₪/L (Oct 2026), stored with the month it is from. The automatic fetch
/// (OutsideProbes.fuel + OutsideParsers.fuelPrice95) stays in the code but is not called in v1.
enum FuelPriceSetting {
    struct Value: Codable, Equatable {
        var priceIls: Double
        /// yyyy-MM
        var month: String
        var source: String
    }

    static let key = "fuelPrice"
    static let defaultValue = Value(priceIls: 8.27, month: "2026-10", source: "manual")

    static func load(_ database: AppDatabase?) -> Value? {
        guard let db = database,
              let json = try? db.writer.read({ try String.fetchOne($0, sql: "SELECT json FROM setting WHERE key = ?", arguments: [key]) }),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func save(_ value: Value, database: AppDatabase?) {
        guard let db = database, !db.isReadOnly,
              let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? db.writer.write { d in
            try d.execute(sql: "INSERT OR REPLACE INTO setting (key, json) VALUES (?, ?)", arguments: [key, json])
            try d.execute(sql: "INSERT OR REPLACE INTO fuel_price (month, priceIls, source, fetchedAt) VALUES (?, ?, 'manual', ?)",
                          arguments: [value.month, value.priceIls, now])
        }
        markCheck(value)
    }

    /// First launch: the owner's default. Every launch: check e1 passes by itself.
    static func ensureDefault(database: AppDatabase?) {
        if let value = load(database) {
            markCheck(value)
        } else if database != nil {
            save(defaultValue, database: database)
        } else {
            CheckResults.shared.set("e1", .fail, "Database not open")
        }
    }

    static func markCheck(_ value: Value) {
        CheckResults.shared.set("e1", .pass, "Fuel price setting ready (manual \(text(value)))")
    }

    static func text(_ value: Value) -> String {
        String(format: "%.2f ₪/L, ", value.priceIls) + monthLabel(value.month)
    }

    /// "2026-10" → "Oct 2026"
    static func monthLabel(_ month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return month }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[m - 1]) \(y)"
    }

    /// This month and the 11 before it, newest first ("yyyy-MM").
    static func recentMonths(from date: Date = Date()) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        return (0..<12).compactMap { back in
            guard let d = calendar.date(byAdding: .month, value: -back, to: date) else { return nil }
            return String(format: "%04ld-%02ld", calendar.component(.year, from: d), calendar.component(.month, from: d))
        }
    }
}

/// Settings → Fuel price (manual, D4 S).
struct FuelPriceView: View {
    @State private var price = ""
    @State private var month = FuelPriceSetting.defaultValue.month
    @State private var saved: String?

    var body: some View {
        Form {
            Section {
                TextField("₪ per litre", text: $price)
                    .keyboardType(.decimalPad)
                Picker("Price from", selection: $month) {
                    ForEach(months, id: \.self) { m in
                        Text(FuelPriceSetting.monthLabel(m)).tag(m)
                    }
                }
                Button("Save") { save() }
                    .disabled(Double(price.replacingOccurrences(of: ",", with: ".")) == nil)
                if let saved {
                    Text(saved).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("95 octane, self-service. Used only for \"fuel money saved\". The automatic price comes back in v2 if a stable source is found.")
            }
        }
        .navigationTitle("Fuel price")
        .screen("Fuel price")
        .onAppear(perform: load)
    }

    private var months: [String] {
        var list = FuelPriceSetting.recentMonths()
        if !list.contains(month) { list.append(month) }
        return list
    }

    private func load() {
        let value = FuelPriceSetting.load(AppModel.shared.database) ?? FuelPriceSetting.defaultValue
        price = String(format: "%.2f", value.priceIls)
        month = value.month
    }

    private func save() {
        guard let p = Double(price.replacingOccurrences(of: ",", with: ".")), p > 0, p < 50 else { return }
        let value = FuelPriceSetting.Value(priceIls: p, month: month, source: "manual")
        FuelPriceSetting.save(value, database: AppModel.shared.database)
        saved = "Saved: \(FuelPriceSetting.text(value))"
    }
}
