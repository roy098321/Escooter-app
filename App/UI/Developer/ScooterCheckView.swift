import CorckieCore
import SwiftUI

/// Developer → Scooter: connection, live decode, firmware, read-only status, and the
/// recorded steps carried over from P2 (T7 lock, T14 autostart traps, battery label).
struct ScooterCheckView: View {
    private let model = AppModel.shared
    private let results = CheckResults.shared
    @State private var recording: String?
    @State private var pack = ""

    var body: some View {
        List {
            connectionSection
            liveSection
            scooterSection
            stepSection("b5", title: "Lock (T7)", how: "Record, lock and unlock 3 times (~5 s apart), Stop.") {
                Button("No lock on this scooter") { results.set("b5", .info, "No lock on this scooter (owner)") }
            }
            stepSection("b6", title: "Autostart traps (T14)",
                        how: "Record, walk the scooter ~50 m switched on, spin the wheel on the stand, kick-start, Stop.") {
                EmptyView()
            }
            labelSection
            Section("Bluetooth events") {
                ForEach(model.scooter.events.suffix(15).reversed(), id: \.self) { line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Scooter")
    }

    private var connectionSection: some View {
        Section {
            Text(model.scooter.state)
            if model.scooter.state == "Bluetooth not started" {
                Button("Connect to the scooter") { model.scooter.start() }
            }
            checkLine("b1")
            checkLine("b2")
            checkLine("b3")
            checkLine("b4")
        }
    }

    private var liveSection: some View {
        let frame: ScooterFrame? = model.live.frame
        let speed: String = frame?.speedKmh.map { String(format: "%.1f", $0) } ?? "—"
        let battery: String = frame?.batteryPct.map { "\($0)%" } ?? "—"
        let volts: String = frame?.voltage.map { String(format: "%.2f V", $0) } ?? "—"
        let amps: String = frame?.currentA.map { String(format: "%.2f A", $0) } ?? "—"
        let temp: String = frame?.temperatureC.map { String(format: "%.0f °C", $0) } ?? "—"
        let odo: String = frame?.odometerKm.map { String(format: "%.1f km", $0) } ?? "—"
        let mode: String = frame?.gear.map { "\($0) (cap \(frame?.capKmh ?? 0) km/h)" } ?? "—"
        let light: String = (frame?.headlight ?? false) ? "on" : "off"
        let brake: String = (frame?.brake ?? false) ? "on" : "off"
        return Section("Live (decoded)") {
            HStack {
                big(speed, "km/h")
                big(battery, "battery")
            }
            LabeledContent("Voltage", value: volts)
            LabeledContent("Current", value: amps)
            LabeledContent("Temperature", value: temp)
            LabeledContent("Odometer", value: odo)
            LabeledContent("Mode", value: mode)
            LabeledContent("Light · brake", value: "\(light) · \(brake)")
            LabeledContent("Packets", value: "\(model.scooter.packets) (\(model.scooter.unknownPackets) unknown)")
            LabeledContent("Readings ignored (G1b)", value: "\(model.live.plausibility.ignoredReadings)")
            Text(model.scooter.lastHex.isEmpty ? "—" : model.scooter.lastHex).font(.caption.monospaced())
        }
    }

    private var scooterSection: some View {
        Section("Scooter") {
            LabeledContent("Fingerprint", value: model.scooter.deviceInfo.fingerprint)
            LabeledContent("Untouched services", value: model.scooter.deniedSeen.isEmpty ? "none offered" : "\(model.scooter.deniedSeen.count)")
            ForEach(model.scooter.deniedSeen, id: \.self) { uuid in
                Text(uuid).font(.caption.monospaced())
            }
        }
    }

    private var labelSection: some View {
        Section("Battery label (b7)") {
            checkLine("b7")
            Picker("Pack size on the label", selection: $pack) {
                Text("—").tag("")
                Text("13 Ah").tag("13 Ah")
                Text("16 Ah").tag("16 Ah")
                Text("Other / not shown").tag("other")
            }
            .onChange(of: pack) { _, value in
                if !value.isEmpty { results.set("b7", .info, "Label says: \(value)") }
            }
        }
    }

    private func checkLine(_ id: String) -> some View {
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

    private func stepSection<Extra: View>(_ id: String, title: String, how: String,
                                          @ViewBuilder extra: () -> Extra) -> some View {
        Section(title) {
            checkLine(id)
            Text(how).font(.footnote).foregroundStyle(.secondary)
            if recording == id {
                Button("Stop and check", role: .destructive) { finish(id) }
            } else {
                Button("Record") { begin(id) }
                    .disabled(recording != nil || !model.scooter.connected)
            }
            extra()
        }
    }

    private func begin(_ id: String) {
        recording = id
        PacketLog.shared.step = id
        results.set(id, .pending, "Recording…")
    }

    private func finish(_ id: String) {
        recording = nil
        PacketLog.shared.step = nil
        let rows = PacketLog.shared.rows(forStep: id)
        let packetsA = rows.compactMap { row -> PacketA? in
            if case .a(let a) = Decoder.decode(row.bytes) { return a }
            return nil
        }
        switch id {
        case "b5":
            let locked = Set(packetsA.map(\.locked))
            let bytes4 = Set(packetsA.map { String(format: "%02X", $0.status) }).sorted().joined(separator: " ")
            let bytes14 = Set(packetsA.map { String(format: "%02X", $0.flags) }).sorted().joined(separator: " ")
            results.set(id, locked.count == 2 ? .pass : .fail,
                        "\(rows.count) packets · byte 4: \(bytes4) · byte 14: \(bytes14)")
        case "b6":
            results.set(id, .info, "\(rows.count) packets recorded for Claude (step b6 in the export)")
        default:
            break
        }
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
