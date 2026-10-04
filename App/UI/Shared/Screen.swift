import SwiftUI

/// The screen on display, for the Bluetooth event log (B04: tell app-caused drops from radio drops).
enum Screen {
    static var current = "Home"
}

extension View {
    /// Records this screen as the one on display while it's visible.
    func screen(_ name: String) -> some View {
        onAppear { Screen.current = name }
    }
}
