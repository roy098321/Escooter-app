import CorckieCore
import CorckieSim
import SwiftUI

/// Developer → Simulated scooter (TESTING §5): replay an anonymised P2 ride through the real
/// pipeline at 1×–50×, optionally with a fault scenario.
struct SimulatorView: View {
    @Bindable private var sim = AppModel.shared.simulator
    private let model = AppModel.shared
    private let results = CheckResults.shared

    var body: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(results.status("d1").icon)
                    VStack(alignment: .leading) {
                        Text("D1 · Simulator ride at 50×")
                        Text(results.note("d1").isEmpty ? "Ride 1 · 50× · No fault → Start" : results.note("d1"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Replay") {
                Picker("Ride", selection: $sim.fixtureID) {
                    ForEach(SimFixture.all) { fixture in
                        Text(fixture.title).tag(fixture.id)
                    }
                }
                Picker("Speed", selection: $sim.speed) {
                    ForEach(VirtualClock.appSpeeds, id: \.self) { speed in
                        Text("\(Int(speed))×").tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Fault", selection: $sim.scenarioID) {
                    ForEach(SimScenario.all.filter(\.playable)) { scenario in
                        Text(scenario.id == "clean" ? scenario.title : "\(scenario.id) · \(scenario.title)").tag(scenario.id)
                    }
                }
                if sim.running {
                    ProgressView(value: sim.progress)
                    Button("Stop", role: .destructive) { sim.stop(reason: "Stopped") }
                } else {
                    Button("Start") { sim.start(realScooterConnected: model.scooter.connected) }
                }
                if let message = sim.message {
                    Text(message).font(.footnote)
                }
            }
            Section("Simulated scooter (decoded)") {
                let f = sim.pipeline.frame
                LabeledContent("Speed", value: f?.speedKmh.map { String(format: "%.1f km/h", $0) } ?? "—")
                LabeledContent("Battery", value: f?.batteryPct.map { "\($0)%" } ?? "—")
                LabeledContent("Temperature", value: f?.temperatureC.map { String(format: "%.0f °C", $0) } ?? "—")
                LabeledContent("Energy so far", value: String(format: "%.0f Wh", sim.pipeline.totals.energyWhRaw))
                LabeledContent("Distance", value: String(format: "%.2f km", sim.pipeline.totals.distanceKm))
                LabeledContent("Readings ignored", value: "\(sim.pipeline.plausibility.ignoredReadings)")
                LabeledContent("Data format", value: sim.pipeline.plausibility.formatChanged
                               ? "changed · \(sim.pipeline.plausibility.formatChangeReason ?? "")" : "OK")
                LabeledContent("Link", value: sim.pipeline.connected ? "connected" : "disconnected")
            }
            Section {
                Text("Simulated rides never touch your real data. The simulator refuses to run while the real scooter is connected and stops if it connects.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Simulated scooter")
        .screen("Simulated scooter")
    }
}
