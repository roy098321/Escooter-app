import CorckieCore
import SwiftUI
import UIKit

// Note 13: the F-28 speed / battery charts were replaced by the one ride graph (RideGraphView). The orientation lock stays here.

/// F-28: the app is portrait; the full-screen charts open it to landscape while they are shown (AppDelegate asks this).
enum OrientationLock {
    @MainActor static var mask: UIInterfaceOrientationMask = .portrait

    @MainActor static func allow(landscape: Bool) {
        mask = landscape ? .allButUpsideDown : .portrait
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            var vc = window.rootViewController
            while let c = vc {
                c.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = c.presentedViewController
            }
        }
        if !landscape { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
    }
}
