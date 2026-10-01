import SwiftUI
import CoreBluetooth

// D03 / D04 / D05: one Bluetooth link to the RND G100, shared by every scooter test.
// Read-only: never writes to the scooter, never touches the firmware-update services.
// State restoration lets iOS relaunch the app when the scooter turns on (D05).
final class Scooter: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = Scooter()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private let dataService = CBUUID(string: "FFF0")
    private let statusStream = CBUUID(string: "FFF2")
    private let deviceInfo = CBUUID(string: "180A")
    private let defaults = UserDefaults.standard

    @Published var state = "Starting Bluetooth…"
    @Published var connected = false
    @Published var speed: Double?
    @Published var battery: Int?
    @Published var voltage: Double?
    @Published var odometer: Double?
    @Published var temperature: Int?
    @Published var current: Double?
    @Published var packets = 0
    @Published var packetsWhileLocked = 0
    @Published var lastHex = ""
    @Published var deviceInfoText: [String] = []
    @Published var events: [String] = []
    @Published var step: String?

    private struct Row {
        let time: Date
        let step: String
        let background: Bool
        let bytes: [UInt8]
    }

    private var log: [Row] = []
    private var seen: [String: [Int: Set<UInt8>]] = [:]   // step → byte index (packet B = 100 + index) → values
    private var minSpeed: [String: Double] = [:]
    private var tempMissing: [String: Bool] = [:]
    private var tempAfterMissing: [String: Bool] = [:]

    private var savedID: UUID? {
        get { defaults.string(forKey: "scooterID").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "scooterID") }
    }

    private var inBackground: Bool { UIApplication.shared.applicationState == .background }

    private override init() {
        super.init()
        events = defaults.stringArray(forKey: "bleEvents") ?? []
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "p2lab.scooter"])
    }

    private func event(_ text: String) {
        let line = "\(Date.now.formatted(date: .abbreviated, time: .standard)) \(text) · \(inBackground ? "app in background" : "app open")"
        events.append(line)
        if events.count > 300 { events.removeFirst(events.count - 300) }
        defaults.set(events, forKey: "bleEvents")
    }

    // MARK: Connection

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
            event("iOS relaunched the app for the scooter")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            state = "Bluetooth isn't available"
            return
        }
        if let known = peripheral, known.state == .connected {
            didBecomeConnected(known)
        } else if let id = savedID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
            known.delegate = self
            state = "Waiting for the scooter · switch it on"
            central.connect(known)
        } else {
            state = "Looking for the scooter · switch it on"
            central.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = found.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        guard name == "G2" || maker.range(of: Data([0x52, 0x4E, 0x44])) != nil else { return }  // "RND"
        central.stopScan()
        peripheral = found
        found.delegate = self
        savedID = found.identifier
        state = "Found the scooter · connecting…"
        central.connect(found)
    }

    func centralManager(_ central: CBCentralManager, didConnect connectedPeripheral: CBPeripheral) {
        event("Connected")
        if inBackground {
            ResultStore.shared.set("d05wake", .pass, "Connected while the app was in the background")
            LocationModel.shared.start(fromBackground: true)
            AltitudeRecorder.shared.start()
        }
        didBecomeConnected(connectedPeripheral)
    }

    private func didBecomeConnected(_ p: CBPeripheral) {
        connected = true
        state = "Connected · waiting for data"
        if ResultStore.shared.status("d03conn") != .pass {
            ResultStore.shared.set("d03conn", .pass, "Connected to \(p.name ?? "the scooter")")
        }
        p.discoverServices([dataService, deviceInfo])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        event("Connection failed")
        central.connect(failed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral, error: Error?) {
        connected = false
        event("Disconnected")
        state = "Disconnected · waiting for the scooter"
        central.connect(lost)   // a pending connect: iOS completes it whenever the scooter is back, even in the background
    }

    // MARK: Data

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for service in p.services ?? [] {
            if service.uuid == dataService { p.discoverCharacteristics([statusStream], for: service) }
            if service.uuid == deviceInfo { p.discoverCharacteristics(nil, for: service) }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == statusStream {
                p.setNotifyValue(true, for: characteristic)
                state = "Connected · receiving data"
            } else if service.uuid == deviceInfo, characteristic.properties.contains(.read) {
                p.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.service?.uuid == deviceInfo {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
                ?? data.map { String(format: "%02X", $0) }.joined()
            deviceInfoText.append("\(characteristic.uuid): \(text)")
            ResultStore.shared.set("t9", .pass, deviceInfoText.joined(separator: " · "))
            return
        }
        handle([UInt8](data))
    }

    private func handle(_ b: [UInt8]) {
        packets += 1
        let background = inBackground
        if background { packetsWhileLocked += 1 }
        lastHex = b.map { String(format: "%02X", $0) }.joined(separator: " ")
        log.append(Row(time: .now, step: step ?? (background ? "background" : "live"), background: background, bytes: b))
        if log.count > 60_000 { log.removeFirst(10_000) }

        func le(_ start: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(b[start + $1]) << (8 * $1) }
        }
        if b.count == 20 {          // packet A
            speed = Double(le(6, 2)) * 0.0476
            voltage = Double(le(8, 2)) / 100
            odometer = Double(le(10, 4)) / 10
            battery = Int(b[18])
        } else if b.count == 11 {   // packet B
            let t = le(0, 2)
            temperature = t == 0xFFFF ? nil : t
            current = Double(le(8, 2)) / 100
        }

        checkLiveData()
        if packetsWhileLocked >= 100, ResultStore.shared.status("d05ble") != .pass {
            ResultStore.shared.set("d05ble", .pass, "\(packetsWhileLocked) packets received while locked")
        }

        guard let id = step else { return }
        let offset = b.count == 20 ? 0 : 100
        for (i, value) in b.enumerated() {
            seen[id, default: [:]][offset + i, default: []].insert(value)
        }
        if b.count == 20, let s = speed, s > 0 {
            minSpeed[id] = min(minSpeed[id] ?? s, s)
        }
        if b.count == 11 {
            if le(0, 2) == 0xFFFF { tempMissing[id] = true } else if tempMissing[id] == true { tempAfterMissing[id] = true }
        }
    }

    private func checkLiveData() {
        guard ResultStore.shared.status("d03data") != .pass,
              let v = voltage, let bat = battery, let s = speed else { return }
        let sensible = (40...56).contains(v) && (0...100).contains(bat) && (0...60).contains(s)
        ResultStore.shared.set("d03data", sensible ? .pass : .fail,
                               String(format: "%.1f km/h · %d%% · %.2f V", s, bat, v))
    }

    // MARK: D04 steps

    func begin(_ id: String) {
        step = id
        seen[id] = [:]
        minSpeed[id] = nil
        tempMissing[id] = false
        tempAfterMissing[id] = false
        ResultStore.shared.set(id, .pending, "Recording…")
    }

    func finish() {
        guard let id = step else { return }
        step = nil
        let s = seen[id] ?? [:]
        let store = ResultStore.shared
        func values(_ i: Int) -> Set<UInt8> { s[i] ?? [] }
        func toggled(_ i: Int, _ mask: UInt8) -> Bool {
            let v = values(i)
            return v.contains { $0 & mask != 0 } && v.contains { $0 & mask == 0 }
        }
        func hex(_ v: Set<UInt8>) -> String { v.sorted().map { String(format: "%02X", $0) }.joined(separator: " ") }

        switch id {
        case "t0":
            let n = log.filter { $0.step == id }.count
            store.set(id, n >= 50 ? .pass : .fail, "\(n) packets in the baseline")
        case "t1":
            store.set(id, toggled(17, 0x01) ? .pass : .fail, "Byte 17 values: \(hex(values(17)))")
        case "t2":
            let modes = values(5).sorted().map { String($0) }
            store.set(id, modes.count >= 2 ? .pass : .fail, "Modes seen (byte 5): \(modes.joined(separator: ", "))")
        case "t3":
            store.set(id, toggled(4, 0x08) ? .pass : .fail, "Byte 4 values: \(hex(values(4)))")
        case "t4":
            let known: Set<Int> = [6, 7, 8, 9, 10, 11, 12, 13, 18, 100, 101, 108, 109]
            let candidates = s.filter { !known.contains($0.key) && $0.value.count >= 3 }.keys.sorted()
            store.set(id, .info, candidates.isEmpty
                      ? "No other byte changed: probably no throttle signal"
                      : "Bytes that changed: " + candidates.map { $0 >= 100 ? "B\($0 - 100)" : "A\($0)" }.joined(separator: ", "))
        case "t7":
            store.set(id, (toggled(4, 0x40) || toggled(14, 0x10)) ? .pass : .fail,
                      "Byte 4: \(hex(values(4))) · byte 14: \(hex(values(14)))")
        case "t8":
            store.set(id, values(4).contains { $0 & 0x80 != 0 } ? .pass : .fail, "Byte 4 values: \(hex(values(4)))")
        case "t10":
            store.set(id, .info, "Current bytes: \(hex(values(108))) · recorded for Claude")
        case "t11":
            store.set(id, (tempMissing[id] == true && tempAfterMissing[id] == true) ? .pass : .fail,
                      tempMissing[id] == true ? "No reading until the motor ran, then a value" : "Temperature was there from the start")
        case "t13":
            if let m = minSpeed[id] {
                store.set(id, m <= 2.05 ? .pass : .fail, String(format: "Lowest speed reported: %.2f km/h", m))
            } else {
                store.set(id, .fail, "No movement recorded")
            }
        case "t14":
            store.set(id, .info, "Recorded for Claude to analyse")
        default:
            break
        }
    }

    func csv() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "time,step,app_state,bytes\n"
        for row in log {
            out += "\(formatter.string(from: row.time)),\(row.step),\(row.background ? "background" : "open"),"
                + row.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "\n"
        }
        return out
    }
}

// MARK: - D03

struct BLETestView: View {
    @ObservedObject private var scooter = Scooter.shared
    @ObservedObject private var store = ResultStore.shared

    var body: some View {
        List {
            Section {
                Text(scooter.state)
                check("d03conn")
                check("d03data")
            }
            Section {
                HStack {
                    big(scooter.speed.map { String(format: "%.1f", $0) } ?? "—", "km/h")
                    big(scooter.battery.map { "\($0)%" } ?? "—", "battery")
                }
            }
            Section("Decoded") {
                LabeledContent("Voltage", value: scooter.voltage.map { String(format: "%.2f V", $0) } ?? "—")
                LabeledContent("Odometer", value: scooter.odometer.map { String(format: "%.1f km", $0) } ?? "—")
                LabeledContent("Temperature", value: scooter.temperature.map { "\($0) °C" } ?? "—")
                LabeledContent("Motor current", value: scooter.current.map { String(format: "%.2f A", $0) } ?? "—")
                LabeledContent("Packets", value: "\(scooter.packets)")
            }
            Section("Last packet") {
                Text(scooter.lastHex.isEmpty ? "—" : scooter.lastHex).font(.footnote.monospaced())
            }
        }
        .navigationTitle("D03 Bluetooth")
    }

    private func check(_ id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.status(id).icon)
            VStack(alignment: .leading) {
                Text(Tests.all.first { $0.id == id }?.title ?? id)
                if !store.note(id).isEmpty { Text(store.note(id)).font(.footnote).foregroundStyle(.secondary) }
            }
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

// MARK: - D04

struct D04Step: Identifiable {
    let id: String
    let title: String
    let how: String
}

private let d04Steps: [D04Step] = [
    D04Step(id: "t0", title: "T0 Baseline", how: "Scooter on, standing still. Record, touch nothing for 30 s, Stop."),
    D04Step(id: "t1", title: "T1 Headlight", how: "Record, turn the light on and off 3 times (~5 s apart), Stop."),
    D04Step(id: "t2", title: "T2 Modes", how: "Record, step through every mode (~10 s each), twice, Stop."),
    D04Step(id: "t3", title: "T3 Brake", how: "Record, squeeze and release the brake 3 times, Stop."),
    D04Step(id: "t4", title: "T4 Throttle", how: "Lift the driving wheel. Record, throttle slowly from 0 to full over ~5 s and release, 3 times, Stop."),
    D04Step(id: "t7", title: "T7 Lock", how: "Only if the display has a lock: Record, lock and unlock 3 times, Stop."),
    D04Step(id: "t9", title: "T9 Device info", how: "Read automatically when connected. Nothing to do."),
    D04Step(id: "t10", title: "T10 Charging", how: "Record, plug in the charger with the scooter on, wait ~2 min, Stop."),
    D04Step(id: "t11", title: "T11 Cold start", how: "Next morning, scooter still off: Record, switch it on, ride off slowly, Stop."),
    D04Step(id: "t13", title: "T13 Lowest speed", how: "Wheel lifted: Record, throttle very gently from 0; then walk the scooter slowly. Stop."),
    D04Step(id: "t14", title: "T14 Autostart traps", how: "Record, walk the scooter (on) ~50 m, spin the wheel on the stand, kick-start with zero-start off, Stop."),
    D04Step(id: "t8", title: "T8 Power off (do last)", how: "Record, switch the scooter off, wait 10 s, Stop.")
]

struct D04View: View {
    @ObservedObject private var scooter = Scooter.shared
    @ObservedObject private var store = ResultStore.shared
    @State private var pack = ""

    var body: some View {
        List {
            Section {
                Text(scooter.state)
                Text("Do the steps in order: Record, do the action, Stop. The result shows right away.")
                    .font(.footnote)
            }
            ForEach(d04Steps) { item in
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(store.status(item.id).icon)
                        Text(item.title).font(.headline)
                    }
                    Text(store.note(item.id).isEmpty || store.note(item.id) == "Recording…" ? item.how : store.note(item.id))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if item.id != "t9" {
                        if scooter.step == item.id {
                            Button("Stop and check", role: .destructive) { scooter.finish() }
                        } else {
                            Button("Record") { scooter.begin(item.id) }
                                .disabled(scooter.step != nil || (!scooter.connected && item.id != "t11"))
                        }
                    }
                }
            }
            Section("Battery label") {
                Picker("Pack size on the label", selection: $pack) {
                    Text("—").tag("")
                    Text("13 Ah").tag("13 Ah")
                    Text("16 Ah").tag("16 Ah")
                    Text("Other / not shown").tag("other")
                }
                .onChange(of: pack) { _, value in
                    if !value.isEmpty { store.set("pack", .info, "Label says: \(value)") }
                }
            }
        }
        .navigationTitle("D04 Scooter data")
    }
}
