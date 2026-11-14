import CorckieCore
import SwiftUI

/// D2 section 6: Settings -> Data & backup -> Start fresh. For a new scooter: a backup first (mandatory), then the scooter's data
/// starts over; the rider chooses whether places, routes and ride times come along. What counts as rider or scooter data is `DataMap`.
struct StartFreshView: View {
    @State private var keepRider = false
    @State private var confirming = false
    @State private var working = false
    @State private var message: String?
    @State private var finished = false
    @State private var canBringBack = false      // A2
    @State private var bringing = false
    @State private var bringMessage: String?

    /// A2: shown after a blank start (rider info not kept), while a backup exists and nothing was brought back yet
    private func refreshCanBringBack() {
        guard let db = AppModel.shared.database else { canBringBack = false; return }
        let kept = SettingsValue.number(db, StartFresh.keptRiderKey)
        let brought = SettingsValue.number(db, StartFresh.broughtBackKey)
        canBringBack = kept == 0 && brought == nil && StartFresh.latestBackup(db) != nil
    }

    private func bringBack() {
        guard let db = AppModel.shared.database, let backup = StartFresh.latestBackup(db), !bringing else { return }
        bringing = true
        bringMessage = nil
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        Task.detached {
            do {
                let n = try StartFresh.bringRiderInfoBack(db, from: backup, nowMs: now)
                await MainActor.run {
                    bringing = false
                    canBringBack = false
                    bringMessage = "Done. \(n) rides are back."
                }
            } catch {
                await MainActor.run {
                    bringing = false
                    bringMessage = "Nothing was changed: \(error.localizedDescription)"
                }
            }
        }
    }

    var body: some View {
        List {
            Section {
                Text("For a new scooter. Your data is backed up first. The scooter's battery numbers, charges and estimates start over; rides and places stay in the backup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep my places, routes and ride times", isOn: $keepRider)
                Text("Battery numbers always start over for the new scooter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(working ? "Working\u{2026}" : "Back up and start fresh", role: .destructive) { confirming = true }
                    .disabled(working || finished || AppModel.shared.database == nil)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(finished ? Theme.ok : Theme.danger)
                }
            }
            if canBringBack || bringMessage != nil {
                Section {
                    if canBringBack {
                        Button(bringing ? "Working\u{2026}" : "Bring rider info back") { bringBack() }
                            .disabled(bringing)
                        Text("Your places, routes and old rides return from the backup. The new scooter's battery numbers stay new.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let bringMessage {
                        Text(bringMessage).font(.footnote).foregroundStyle(Theme.ok)
                    }
                }
            }
        }
        .onAppear { refreshCanBringBack() }
        .navigationTitle("Start fresh")
        .alert("Start fresh?", isPresented: $confirming) {
            Button("Start fresh", role: .destructive) { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(keepRider ? "A backup is made first. Battery numbers start over; your places, routes and ride times stay."
                           : "A backup is made first. Everything starts over, including places and routes.")
        }
    }

    private func run() {
        guard let db = AppModel.shared.database, !working else { return }
        working = true
        message = nil
        let keep = keepRider
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let offset = TimeZone.current.secondsFromGMT() / 60
        Task.detached {
            do {
                // 1. the backup is mandatory: if it cannot be written, nothing is deleted
                try StartFresh.localBackup(db, nowMs: now)
                var filesNote = ""
                if BackupFolder.shared.hasFolder {
                    do {
                        try BackupFolder.shared.withFolder { root in
                            _ = try BackupWriter.perform(db: db, root: root, rideId: nil, fullDue: true, nowMs: now, offsetMin: offset)
                        }
                        filesNote = " A copy is also in your backup folder."
                    } catch {
                        filesNote = " The backup folder could not be written, but the copy on this phone is complete."
                    }
                }
                // 2. the reset (one transaction)
                try StartFresh.reset(db, keepRider: keep, nowMs: now)
                await MainActor.run {
                    // 3. forget the old pairing (1d) so onboarding runs for the new scooter
                    AppModel.shared.scooter.forget()
                    ScooterRecord.forgetPairing(in: db)
                    OnboardingState.done = false
                    let defaults = UserDefaults.standard
                    for key in ["corckie.lastSeenMs", "corckie.lastSeenPct", "corckie.lastSeenSpot"] { defaults.removeObject(forKey: key) }
                    Log.info(source: "fresh", "Start fresh done (rider info \(keep ? "kept" : "cleared"))")
                    working = false
                    finished = true
                    message = "Done. Switch on the new scooter and tap Connect on Home." + filesNote
                }
            } catch {
                await MainActor.run {
                    working = false
                    message = "Nothing was changed: \(error.localizedDescription)"
                }
            }
        }
    }
}
