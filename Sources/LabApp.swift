import SwiftUI

// P2 Lab: one throwaway app for every remaining P2 check, with a pass / fail mark on each.
@main
struct LabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashLab.shared.start()
        // Recreate the Bluetooth link at launch so iOS can relaunch the app for the scooter (D05).
        if UserDefaults.standard.string(forKey: "scooterID") != nil {
            _ = Scooter.shared
        }
        return true
    }
}

struct RootView: View {
    @ObservedObject private var store = ResultStore.shared
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ResultsView()
                    } label: {
                        Label("Results and export", systemImage: "checklist")
                            .font(.headline)
                    }
                } footer: {
                    Text("✅ passed · ❌ failed · ◐ partly done · ⏳ not done yet · ℹ️ recorded for Claude")
                }
                Section("Phone only") {
                    row("D08 Backup folder", ["d08", "d08r"]) { BackupTestView() }
                    row("D09 Crash reports", ["d09own", "d09mk"]) { CrashTestView() }
                    row("D10 Ride Replay viewer", ["d10"]) { ReplayTestView() }
                    row("D07 Barometer", ["d07baro"]) { BaroTestView() }
                    row("D05 Background location", ["d05loc"]) { LocationTestView() }
                }
                Section("Scooter standing still") {
                    row("D03 Bluetooth", ["d03conn", "d03data"]) { BLETestView() }
                    row("D04 Scooter data (T0–T14)",
                        ["t0", "t1", "t2", "t3", "t4", "t7", "t9", "t10", "t11", "t13", "t14", "t8", "pack"]) { D04View() }
                }
                Section("On a ride") {
                    row("D05 + D07 Ride test", ["d05wake", "d05ble", "d05locwake", "d05ride", "d07bridge"]) { RideTestView() }
                    row("D11 Readability", ["d11read", "d11sun"]) { ReadabilityView() }
                }
                Section {
                    Text("Build \(build)").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("P2 Lab")
        }
    }

    private func row<Destination: View>(_ title: String, _ ids: [String],
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(store.badge(ids))
                Text(title)
            }
        }
    }
}
