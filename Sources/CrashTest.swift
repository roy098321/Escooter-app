import SwiftUI
import MetricKit

// D09: do iOS crash reports (MetricKit) reach a sideloaded app? Plus our own catcher:
// if the app was in the foreground when the last session ended, it closed unexpectedly.
final class CrashLab: NSObject, ObservableObject, MXMetricManagerSubscriber {
    static let shared = CrashLab()

    @Published var reports: [String] = UserDefaults.standard.stringArray(forKey: "mxReports") ?? []
    @Published var lastRunCrashed = false

    func start() {
        let defaults = UserDefaults.standard
        lastRunCrashed = defaults.bool(forKey: "wasInForeground")
        if lastRunCrashed {
            ResultStore.shared.set("d09own", .pass, "Noticed that the last session ended unexpectedly")
        }
        defaults.set(true, forKey: "wasInForeground")
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            defaults.set(false, forKey: "wasInForeground")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            defaults.set(true, forKey: "wasInForeground")
        }
        MXMetricManager.shared.add(self)
        MXMetricManager.shared.pastDiagnosticPayloads.forEach(record)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        payloads.forEach(record)
    }

    private func record(_ payload: MXDiagnosticPayload) {
        let crashes = payload.crashDiagnostics?.count ?? 0
        let line = "\(payload.timeStampEnd.formatted()) · \(crashes) crash report(s)"
        DispatchQueue.main.async {
            if crashes > 0 {
                ResultStore.shared.set("d09mk", .pass, "iOS delivered a crash report")
            }
            guard !self.reports.contains(line) else { return }
            self.reports.append(line)
            UserDefaults.standard.set(self.reports, forKey: "mxReports")
        }
    }
}

struct CrashTestView: View {
    @ObservedObject private var lab = CrashLab.shared

    var body: some View {
        List {
            Section("Our own catcher") {
                Text(lab.lastRunCrashed ? "⚠️ The last session ended unexpectedly" : "The last session ended normally")
                HStack { Text(ResultStore.shared.status("d09own").icon); Text("D09 Our crash catcher") }
                HStack { Text(ResultStore.shared.status("d09mk").icon); Text("D09 iOS crash report arrives") }
            }
            Section("iOS crash reports (MetricKit)") {
                if lab.reports.isEmpty {
                    Text("None received yet. iOS delivers them up to a day later.")
                        .foregroundStyle(.secondary)
                }
                ForEach(lab.reports, id: \.self) { line in
                    Text(line).font(.footnote.monospaced())
                }
            }
            Section {
                Button("Crash the app now", role: .destructive) {
                    fatalError("P2 Lab test crash")
                }
            } footer: {
                Text("Then reopen the app: our catcher should say the last session ended unexpectedly. Check back tomorrow for the iOS report.")
            }
        }
        .navigationTitle("Crash reports")
    }
}
