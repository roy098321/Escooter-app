import SwiftUI

/// "v1 · 1.0 (183)": the product version (owner, P4_DILEMMAS D3; the Home Screen name is just "CorckieApp").
///
/// G4 (P6-2 declutter, owner approved 18 Oct): the tag no longer sits on every screen (it was on the live view too). It is shown
/// in one place only, Settings → About, as this label. `VersionLabelGuardTests` (Linux CI) fails the build if it shows up anywhere else.
struct VersionLabel: View {
    var body: some View {
        Text(AppInfo.v1Line)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Version 1, build \(AppInfo.versionLine)")
    }
}
