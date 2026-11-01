import CorckieCore
import SwiftUI

/// Batch 102 lab: Developer → Voice messages (V09): every V09 line once (no ride needed), or one at a time. Made-up numbers.
struct V09PlayAllView: View {
    var body: some View {
        List {
            Section {
                Button {
                    RideVoice.shared.playAllV09()
                } label: {
                    Label("Play every message once", systemImage: "play.circle.fill").font(.headline)
                }
            } footer: {
                Text("About one every 4 seconds. Urgent ones are said at once on a ride; the others wait for a stop or a straight stretch.")
            }
            Section("Tap one to hear it") {
                ForEach(Array(V09Message.samples.enumerated()), id: \.offset) { _, m in
                    Button { SoundPlayer.shared.say(m.line) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.line).font(.subheadline).foregroundStyle(Color.primary)
                            Text(m.urgent ? "urgent: at once" : "can wait: at a good moment").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Voice messages")
        .navigationBarTitleDisplayMode(.inline)
        .screen("Voice messages")
    }
}
