import SwiftUI
import UIKit

/// F-30 (owner, 20 Oct): the build number as a tiny grey stamp, "1.0 (229)" (CFBundleShortVersionString and CFBundleVersion; CI sets the
/// build to the run number, so it is the same number as the artifact name). It sits centred in the gap between the tab bar and the home
/// indicator on every tab, and at the same spot above the home indicator on pushed screens that have no tab bar. It is drawn over the
/// app's root, so sheets and the ride cover (which are presented above it) are never covered by it. Caption2, tertiary colour, not tappable.
enum BuildStamp {
    /// The one flag: set it to false to remove the stamp near the end of the project.
    static let isVisible = true

    static var text: String { AppInfo.versionLine }

    /// the home indicator's inset on this phone (0 on phones with a home button)
    @MainActor static var bottomInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    /// the indicator itself is about 5 pt tall and 8 pt above the screen edge; the stamp is centred between the tab bar and it
    static let belowIndicator: CGFloat = 13
}

extension View {
    /// F-30: puts the build stamp over this view (the app's root)
    func buildStamp() -> some View {
        modifier(BuildStampModifier())
    }
}

private struct BuildStampModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay {
            if BuildStamp.isVisible {
                let gap = max(14, BuildStamp.bottomInset + FloatingTabBar.bottomGap - BuildStamp.belowIndicator)
                Color.clear
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text(BuildStamp.text)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(height: gap)
                            .padding(.bottom, BuildStamp.belowIndicator)
                    }
                    .allowsHitTesting(false)
            }
        }
    }
}
