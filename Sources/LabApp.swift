import SwiftUI

// P2 Lab: one throwaway app for the phone-side P2 tests (D03, D05, D07–D10).
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
        return true
    }
}

struct RootView: View {
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        NavigationStack {
            List {
                Section("Phone only") {
                    NavigationLink("D08 Backup folder") { BackupTestView() }
                    NavigationLink("D09 Crash reports") { CrashTestView() }
                    NavigationLink("D10 Ride Replay viewer") { ReplayTestView() }
                    NavigationLink("D07 Barometer") { BaroTestView() }
                    NavigationLink("D05 Background location") { LocationTestView() }
                }
                Section("Next to the scooter") {
                    NavigationLink("D03 Bluetooth") { BLETestView() }
                }
                Section {
                    Text("Build \(build)").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("P2 Lab")
        }
    }
}
