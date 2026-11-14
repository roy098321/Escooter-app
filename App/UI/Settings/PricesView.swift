import SwiftUI

/// K3: one "Prices" screen for fuel price, electricity and fuel use, and the price history.
/// Opened from Settings and from Stats → Money.
struct PricesView: View {
    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    FuelPriceView()
                } label: {
                    LabeledContent("Fuel price", value: FuelPriceSetting.load(db).map(FuelPriceSetting.text) ?? "\u{2014}")
                }
                NavigationLink {
                    CostSettingsView()
                } label: {
                    Text("Electricity and fuel use")
                }
                NavigationLink {
                    PriceHistoryView()
                } label: {
                    Text("Price history")
                }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Prices")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Prices")
    }
}
