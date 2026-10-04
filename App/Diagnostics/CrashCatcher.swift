import Foundation
import MetricKit
import UIKit

/// Crash catching (C28b, P2 D09 ✅): our own catcher + MetricKit.
/// Own catcher: if the app was in the foreground when the last session ended, it closed
/// unexpectedly. Uncaught Objective-C exceptions also leave their reason behind.
final class CrashCatcher: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashCatcher()

    private let defaults = UserDefaults.standard
    private static let foregroundKey = "corckie.wasInForeground"
    private static let exceptionKey = "corckie.lastException"
    private static let testCrashKey = "corckie.testCrashRequested"
    private static let reportsKey = "corckie.metricKitReports"

    private(set) var lastRunCrashed = false
    private(set) var lastException: String?
    private(set) var metricKitReports: [String] = []

    func start() {
        lastRunCrashed = defaults.bool(forKey: Self.foregroundKey)
        lastException = defaults.string(forKey: Self.exceptionKey)
        metricKitReports = defaults.stringArray(forKey: Self.reportsKey) ?? []
        defaults.removeObject(forKey: Self.exceptionKey)
        // B06: a phone restart also ends a foreground session; tell it apart by the boot time
        let boot = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        let lastBoot = (defaults.object(forKey: "corckie.crashCatcherBoot") as? Date)
            ?? (defaults.object(forKey: "corckie.lastBootSeen") as? Date)   // build 24 kept this one
        defaults.set(boot, forKey: "corckie.crashCatcherBoot")
        let phoneRestarted = lastBoot.map { abs($0.timeIntervalSince(boot)) > 120 } ?? false
        if lastRunCrashed && phoneRestarted && !defaults.bool(forKey: Self.testCrashKey) {
            lastRunCrashed = false
            Log.info(source: "launch", "Phone restarted since the last session (not a crash)")
        }
        if lastRunCrashed {
            let wasTest = defaults.bool(forKey: Self.testCrashKey)
            Log.error(source: "crash", "The last session ended unexpectedly\(wasTest ? " (test crash)" : "")\(lastException.map { ": \($0)" } ?? "")")
            CheckResults.shared.set("d4", .pass, wasTest ? "Caught the test crash on reopening" : "Caught an unexpected close")
            defaults.set(false, forKey: Self.testCrashKey)
        }
        defaults.set(UIApplication.shared.applicationState != .background, forKey: Self.foregroundKey)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.defaults.set(false, forKey: Self.foregroundKey)
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.defaults.set(true, forKey: Self.foregroundKey)
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.defaults.set(false, forKey: Self.foregroundKey)
        }
        NSSetUncaughtExceptionHandler { exception in
            UserDefaults.standard.set("\(exception.name.rawValue): \(exception.reason ?? "")", forKey: "corckie.lastException")
        }
        MXMetricManager.shared.add(self)
        MXMetricManager.shared.pastDiagnosticPayloads.forEach(record)
    }

    /// Settings → Developer → Crash catcher → "Crash the app now".
    func crashForTest() -> Never {
        defaults.set(true, forKey: Self.testCrashKey)
        defaults.set(true, forKey: Self.foregroundKey)
        fatalError("CorckieApp test crash (Developer → Checks)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        payloads.forEach(record)
    }

    private func record(_ payload: MXDiagnosticPayload) {
        let crashes = payload.crashDiagnostics?.count ?? 0
        let line = "\(payload.timeStampEnd.formatted()) · \(crashes) crash report(s)"
        DispatchQueue.main.async {
            if crashes > 0 {
                CheckResults.shared.set("d5", .pass, "iOS delivered \(crashes) crash report(s)")
                Log.error(source: "metrickit", line)
            }
            guard !self.metricKitReports.contains(line) else { return }
            self.metricKitReports.append(line)
            self.defaults.set(self.metricKitReports, forKey: Self.reportsKey)
        }
    }
}
