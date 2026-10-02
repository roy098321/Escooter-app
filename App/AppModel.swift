import CorckieCore
import Foundation
import Observation
import UIKit

/// Composition root · ARCHITECTURE §2.2 #18: creates the real (or simulated) sources once
/// and hands them to the screens.
@Observable
final class AppModel {
    static let shared = AppModel()

    let scooter = ScooterLink()

    private init() {}

    /// Called at every launch, also when iOS relaunches the app in the background for the
    /// scooter: the Bluetooth central must exist with the same restore ID straight away.
    func launch(options: [UIApplication.LaunchOptionsKey: Any]?) {
        let relaunchedForBluetooth = options?[.bluetoothCentrals] != nil
        if scooter.hasKnownScooter || relaunchedForBluetooth {
            scooter.start()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModel.shared.launch(options: launchOptions)
        return true
    }
}
