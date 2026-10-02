import SwiftUI

/// CorckieApp: the RND G100 companion app (ARCHITECTURE.md).
/// P4 foundation build: an empty-but-real app with the developer tools under Settings.
@main
struct CorckieApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
