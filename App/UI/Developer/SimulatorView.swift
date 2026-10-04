import CorckieCore
import CorckieSim
import SwiftUI

/// Developer → Simulated scooter (TESTING §5): replay an anonymised P2 ride through the real
/// pipeline at 1×–50×, optionally with a fault scenario.
struct SimulatorView: View {
    @Bindable private var sim = AppModel.shared.simulator
    @Bindable private var screens = ScreenSimulator.shared
    private let model = AppModel.shared
    private let results = CheckResults.shared

    var body: some View {
        List {
            Section {
                checkLine("d1", "Ride 1 · 50× · No fault → Start")
                checkLine("d7", "Fault D7 · 50× → Start (uses ride 2, which has GPS)")
                checkLine("d8", "Checked after every run")
                checkLine("d11", "Run on the real screens → watch Home, live view, summary")
            }
            Section("Replay") {
                Picker("Ride", selection: $sim.fixtureID) {
                    ForEach(SimFixture.all) { fixture in
                        Text(fixture.title).tag(fixture.id)
                    }
                }
                .disabled(sim.running)
                Picker("Speed", selection: $sim.speed) {
                    ForEach(VirtualClock.appSpeeds, id: \.self) { speed in
                        Text("\(Int(speed))×").tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(sim.running)
                Picker("Fault", selection: $sim.scenarioID) {
                    ForEach(SimScenario.all.filter(\.playable)) { scenario in
                        Text(scenario.id == "clean" ? scenario.title : "\(scenario.id) · \(scenario.title)").tag(scenario.id)
                    }
                }
                .disabled(sim.running)
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
            Section("Run on the real screens") {
                Picker("Scenario", selection: $screens.sourceID) {
                    ForEach(ScreenSimulator.sources) { s in
                        Text(s.id == "F2" || s.id == "F5" || s.id == "F3" ? s.title : "\(s.id) · \(s.title)").tag(s.id)
                    }
                }
                .disabled(screens.running)
                Picker("Speed", selection: $screens.speed) {
                    ForEach(VirtualClock.appSpeeds, id: \.self) { speed in
                        Text("\(Int(speed))×").tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(screens.running)
                if screens.running {
                    ProgressView(value: screens.progress)
                    Button("Stop", role: .destructive) { screens.stop(reason: "Stopped") }
                } else {
                    Button("Start") {
                        screens.start(realScooterConnected: model.scooter.connected, otherSimulatorRunning: sim.running)
                    }
                }
                if screens.active {
                    Button("End simulation (deletes simulated rides)", role: .destructive) { screens.end() }
                }
                if let message = screens.message {
                    Text(message).font(.footnote)
                }
                Text("Runs the real Home, live view and ride summary on the fake scooter. Simulated rides live in a temporary database and show only while the purple SIMULATED banner is on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Simulated scooter (decoded)") {
                let f = sim.pipeline.frame
                if let gps = sim.gpsSpeedKmh {
                    LabeledContent("Speed") {
                        Text(String(format: "%.0f km/h · GPS (phone took over)", gps)).foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent("Speed", value: f?.speedKmh.map { String(format: "%.1f km/h", $0) } ?? "—")
                }
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

    private func checkLine(_ id: String, _ how: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(results.status(id).icon)
            VStack(alignment: .leading) {
                Text("\(id.uppercased()) · \(CheckList.item(id)?.title ?? id)")
                Text(results.note(id).isEmpty ? how : results.note(id))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
