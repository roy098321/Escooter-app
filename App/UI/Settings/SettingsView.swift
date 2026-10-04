import SwiftUI

/// Settings (FEATURES.md → Settings); the foundation build has About and Developer only.
struct SettingsView: View {
    var body: some View {
        List {
            Section("About") {
                LabeledContent("Version", value: AppInfo.versionLine)
                LabeledContent("App ID", value: AppInfo.bundleID)
            }
            Section("Costs") {
                NavigationLink {
                    FuelPriceView()
                } label: {
                    LabeledContent("Fuel price", value: FuelPriceSetting.load(AppModel.shared.database).map(FuelPriceSetting.text) ?? "—")
                }
            }
            Section {
                NavigationLink {
                    DeveloperView()
                } label: {
                    Label("Developer", systemImage: "hammer")
                }
            } footer: {
                Text("Checks, results and the test tools of this build.")
            }
        }
        .navigationTitle("Settings")
        .screen("Settings")
    }
}

enum AppInfo {
    static let bundleID = Bundle.main.bundleIdentifier ?? "?"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "?"
    static var versionLine: String { "\(version) (\(build))" }
    /// Owner, P4 D3: "v1" is shown inside the app on every screen (the Home Screen name is just "CorckieApp").
    static let productVersion = "v1"
    static var v1Line: String { "\(productVersion) · \(versionLine)" }
}
