import SwiftUI

/// D2 3b: shown on onboarding and on Home when the phone's Bluetooth is the reason there is no scooter connection.
struct BluetoothProblemView: View {
    let problem: ScooterLink.BluetoothProblem

    static func title(_ problem: ScooterLink.BluetoothProblem) -> String {
        switch problem {
        case .off: return "Bluetooth is off"
        case .denied: return "Bluetooth is off for CorckieApp"
        case .unavailable: return "Bluetooth isn't available on this iPhone"
        }
    }

    static func detail(_ problem: ScooterLink.BluetoothProblem) -> String {
        switch problem {
        case .off: return "Turn Bluetooth on in Control Centre, so the app can find your scooter."
        case .denied: return "Allow Bluetooth for CorckieApp in iPhone Settings. The app only reads from the scooter."
        case .unavailable: return "The app needs Bluetooth to read your scooter."
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Label(Self.title(problem), systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.subheadline.weight(.semibold))
            Text(Self.detail(problem))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if problem != .unavailable {
                Button("Open iPhone Settings") { PermissionsCheck.openSettings() }
                    .font(.footnote.weight(.semibold))
            }
        }
    }
}
