import SwiftUI

/// "v1 · 0.4 (13)" on every screen (owner, P4_DILEMMAS D3). The Home Screen name is just
/// "CorckieApp"; inside the app the product version is always visible for future reference.
///
/// One label, placed once: `RootView` applies `.v1Label()` to the whole app, so every tab and
/// every pushed screen has it. Sheets and full-screen covers are separate windows, so their
/// content must call `.v1Label()` too — `VersionLabelGuardTests` (Linux CI) fails the build if
/// a file presents one without it.
///
/// Where: bottom-right corner, in the home-indicator strip below the tab bar, small caption,
/// secondary colour, never takes touches. It sits outside every tile, so on the live ride it
/// can't compete with the speed and battery numbers.
struct VersionLabel: View {
    var body: some View {
        Text(AppInfo.v1Line)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel("Version 1, build \(AppInfo.versionLine)")
    }
}

extension View {
    /// Puts the v1 label in the bottom-right corner of this screen (see `VersionLabel`).
    func v1Label() -> some View {
        overlay(alignment: .bottomTrailing) {
            VersionLabel()
                .padding(.trailing, 16)
                .padding(.bottom, 4)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}
