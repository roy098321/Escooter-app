import SwiftUI
import CoreBluetooth

// D03: connect to the RND G100 and decode its FFF2 stream (docs/PROTOCOL.md).
// Read-only: never writes to the scooter, never touches the firmware-update services.
final class BLEModel: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var scooter: CBPeripheral?
    private let dataService = CBUUID(string: "FFF0")
    private let statusStream = CBUUID(string: "FFF2")

    @Published var state = "Starting Bluetooth…"
    @Published var speed: Double?
    @Published var battery: Int?
    @Published var voltage: Double?
    @Published var odometer: Double?
    @Published var temperature: Int?
    @Published var current: Double?
    @Published var packets = 0
    @Published var lastHex = ""

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            state = "Looking for the scooter… (switch it on)"
            central.scanForPeripherals(withServices: nil)
        } else {
            state = "Bluetooth isn't available (state \(central.state.rawValue))"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        let isRND = name == "G2" || maker.range(of: Data([0x52, 0x4E, 0x44])) != nil  // "RND"
        guard isRND else { return }
        central.stopScan()
        scooter = peripheral
        peripheral.delegate = self
        state = "Found \(name.isEmpty ? "the scooter" : name) · connecting…"
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = "Connected · waiting for data…"
        peripheral.discoverServices([dataService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = "Couldn't connect · looking again…"
        central.scanForPeripherals(withServices: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = "Disconnected · looking again…"
        central.scanForPeripherals(withServices: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == dataService {
            peripheral.discoverCharacteristics([statusStream], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == statusStream {
            peripheral.setNotifyValue(true, for: characteristic)
            state = "Connected · receiving data"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        packets += 1
        lastHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let b = [UInt8](data)
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
    }
}

struct BLETestView: View {
    @StateObject private var model = BLEModel()

    var body: some View {
        List {
            Section {
                Text(model.state)
            }
            Section {
                HStack {
                    big(model.speed.map { String(format: "%.1f", $0) } ?? "—", "km/h")
                    big(model.battery.map { "\($0)%" } ?? "—", "battery")
                }
            }
            Section("Decoded") {
                LabeledContent("Voltage", value: model.voltage.map { String(format: "%.2f V", $0) } ?? "—")
                LabeledContent("Odometer", value: model.odometer.map { String(format: "%.1f km", $0) } ?? "—")
                LabeledContent("Temperature", value: model.temperature.map { "\($0) °C" } ?? "—")
                LabeledContent("Motor current", value: model.current.map { String(format: "%.2f A", $0) } ?? "—")
                LabeledContent("Packets", value: "\(model.packets)")
            }
            Section("Last packet") {
                Text(model.lastHex.isEmpty ? "—" : model.lastHex)
                    .font(.footnote.monospaced())
            }
        }
        .navigationTitle("Bluetooth")
    }

    private func big(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
