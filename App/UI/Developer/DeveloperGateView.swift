import CorckieCore
import SwiftUI

/// N5-4: asks for the Developer password once per app launch (a static flag, so a relaunch asks again).
/// Only the hash is in the code (`DeveloperGate`). A door, not a lock.
struct DeveloperGateView: View {
    private static var unlockedThisLaunch = false
    /// true once the password was entered in this launch (rider screens use it to show developer-only lines)
    static var isUnlocked: Bool { unlockedThisLaunch }
    @State private var unlocked = DeveloperGateView.unlockedThisLaunch
    @State private var attempt = ""
    @State private var wrong = false

    var body: some View {
        if unlocked {
            DeveloperView()
        } else {
            Form {
                Section {
                    SecureField("Password", text: $attempt)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { submit() }
                    Button("Open") { submit() }
                    if wrong {
                        Text("Wrong password.").font(.footnote).foregroundStyle(Theme.danger)
                    }
                } footer: {
                    Text("For testing the app.")
                }
            }
            .navigationTitle("Developer")
        }
    }

    private func submit() {
        if DeveloperGate.accepts(attempt) {
            Self.unlockedThisLaunch = true
            unlocked = true
        } else {
            wrong = true
            attempt = ""
        }
    }
}
