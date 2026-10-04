import Charts
import SwiftUI

/// Developer → Sensors: wake-up and recording while locked (c1–c4), and the elevation chart
/// for the arch bridge (f1).
struct SensorsView: View {
    private let sensors = PhoneSensors.shared
    private let model = AppModel.shared
    private let results = CheckResults.shared

    var body: some View {
        List {
            Section("Before you lock the phone") {
                Text("1. Open Developer → Scooter once with the scooter on, so the app knows it. Allow location \"Always\".")
                Text("2. Switch the scooter off. Go to the Home Screen (don't swipe CorckieApp away) and lock the phone.")
                Text("3. Switch the scooter on with the phone locked. Wait 30 s, then walk ~2 min.")
            }
            .font(.footnote)
            Section("Checks") {
                line("c1")
                line("c2")
                line("c3")
                line("c4")
                line("c5")
                line("c6")
                line("c7")
                line("c8")
            }
            Section("Recording") {
                LabeledContent("Location permission", value: sensors.permission)
                LabeledContent("Fixes", value: "\(sensors.fixes) (\(sensors.fixesInBackground) while locked)")
                LabeledContent("Last fix", value: sensors.lastFix)
                LabeledContent("Barometer", value: "\(sensors.altitude.count) (\(sensors.altitudeInBackground) while locked)")
                LabeledContent("Scooter packets while locked", value: "\(model.scooter.packetsInBackground)")
                LabeledContent("Packet gaps > 2 s", value: "\(sensors.packetGapsOver2s) (longest \(Int(sensors.longestGapS)) s)")
                LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")
                if sensors.recording {
                    Button("Stop recording", role: .destructive) { sensors.stop() }
                } else {
                    Button("Start recording now") { sensors.start() }
                }
            }
            Section("Elevation (arch bridge, f1)") {
                if sensors.altitude.count > 1 {
                    Chart(sensors.altitude) { sample in
                        LineMark(x: .value("Time", sample.time), y: .value("Metres", sample.meters))
                    }
                    .frame(height: 160)
                    Text(String(format: "Highest − lowest: %.1f m", sensors.altitudeRise))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Start recording, then ride over the bridge.").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Does the bridge show as a clear bump?").font(.footnote)
                ManualResult(id: "f1")
            }
        }
        .navigationTitle("Sensors")
        .screen("Sensors")
    }

    private func line(_ id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(results.status(id).icon)
            VStack(alignment: .leading) {
                Text(CheckList.item(id)?.title ?? id)
                if !results.note(id).isEmpty {
                    Text(results.note(id)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
