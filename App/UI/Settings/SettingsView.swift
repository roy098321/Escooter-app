import SwiftUI

/// Settings (FEATURES.md → Settings); the foundation build has About and Developer only.
struct SettingsView: View {
    var body: some View {
        List {
            Section("About") {
                LabeledContent("Version", value: AppInfo.versionLine)
                LabeledContent("App ID", value: AppInfo.bundleID)
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
    }
}

enum AppInfo {
    static let bundleID = Bundle.main.bundleIdentifier ?? "?"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "?"
    static var versionLine: String { "\(version) (\(build))" }
}
