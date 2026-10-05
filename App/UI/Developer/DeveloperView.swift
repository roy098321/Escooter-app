import SwiftUI

/// Settings → Developer: the build's checks, results / export, and the test tools
/// (same app, same bundle ID: no extra app ID, TESTING §5).
struct DeveloperView: View {
    private let results = CheckResults.shared

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ChecksView()
                } label: {
                    Label("Checks", systemImage: "checklist").font(.headline)
                }
                NavigationLink {
                    ResultsView()
                } label: {
                    Label("Results and export", systemImage: "square.and.arrow.up")
                }
                CountsRow()
            } footer: {
                Text("Build \(AppInfo.versionLine) · \(AppInfo.bundleID)")
            }
            Section("Tools") {
                ShowOnboardingRow()
                tool("Permissions", "lock.shield", ["h1"]) { PermissionsView() }
                tool("Scooter", "scooter", ["b1", "b2", "b3", "b4", "b5", "b8", "b9"]) { ScooterCheckView() }
                tool("Sensors (phone locked)", "location", ["c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "f1"]) { SensorsView() }
                tool("Simulated scooter", "play.circle", ["d1", "d7", "d8"]) { SimulatorView() }
                tool("Backup folder", "folder", ["d2", "d3", "d9"]) { BackupView() }
                tool("Crash catcher and error log", "ladybug", ["d4", "d5", "d6"]) { CrashView() }
                tool("Outside data", "cloud.sun", ["e1", "e2", "e3", "e3b", "e4", "e5", "e6", "e6b", "e7", "e8"]) { OutsideDataView() }
                tool("Readability", "sun.max", ["f2", "f3"]) { ReadabilityView() }
                tool("Insights (simulated windy week)", "text.bubble", ["u32", "mi1"]) { InsightsView() }
            }
        }
        .navigationTitle("Developer")
        .screen("Developer")
    }

    private func tool<Destination: View>(_ title: String, _ symbol: String, _ ids: [String],
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(badge(ids))
            }
        }
    }

    private func badge(_ ids: [String]) -> String {
        let all = ids.map { results.status($0) }
        if all.contains(.fail) { return "❌" }
        if all.allSatisfy({ $0 == .pending }) { return "⏳" }
        if all.contains(.pending) { return "◐" }
        return "✅"
    }
}
