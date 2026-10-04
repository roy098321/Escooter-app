import CoreBluetooth
import CorckieCore
import Foundation
import Observation
import UIKit

/// ScooterLink · ARCHITECTURE §2.2 #1, §1.4, §5.1.
///
/// READ-ONLY BY CONSTRUCTION: this type subscribes to the status stream and reads Device
/// Information, nothing else. It has no function that sends anything to the scooter, and
/// every service / characteristic on `ScooterGatt.denied` (commands, firmware update) is
/// skipped at discovery. `ReadOnlyGuardTests` (CorckieCore, Linux CI) fails the build if a
/// write call or a denied UUID ever appears in this folder.
///
/// State restoration (`corckieapp.scooter`) lets iOS relaunch the app when the scooter
/// turns on (P2 D05 ✅).
@Observable
final class ScooterLink: NSObject {
    static let restoreID = "corckieapp.scooter"
    private static let savedIDKey = "corckie.scooterPeripheralID"
    private static let eventsKey = "corckie.bleEvents"

    // Listeners (packet log, checks, simulator safety). Called on the main queue.
    @ObservationIgnored var packetHandlers: [([UInt8], Date, Bool) -> Void] = []
    @ObservationIgnored var connectHandlers: [(_ inBackground: Bool) -> Void] = []
    @ObservationIgnored var disconnectHandlers: [(_ reason: String) -> Void] = []
    /// Events can only be saved once the files are readable (after the first unlock after a restart).
    @ObservationIgnored private var eventsLoaded = false

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var assembler = FrameAssembler()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let started = Date()

    private(set) var state = "Bluetooth not started"
    private(set) var connected = false
    private(set) var frame: ScooterFrame?
    private(set) var packets = 0
    private(set) var packetsInBackground = 0
    private(set) var unknownPackets = 0
    private(set) var lastHex = ""
    private(set) var deviceInfo = DeviceInfo()
    /// Denied UUIDs the scooter offered; listed so the owner can see they were never touched.
    private(set) var deniedSeen: [String] = []
    private(set) var events: [String] = []

    var hasKnownScooter: Bool { savedID != nil }
    var knownPeripheralID: String? { savedID?.uuidString }
    @ObservationIgnored private var connectedAt: Date?

    private var savedID: UUID? {
        get { defaults.string(forKey: Self.savedIDKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.savedIDKey) }
    }

    private var inBackground: Bool { UIApplication.shared.applicationState == .background }

    override init() {
        super.init()
        loadEventsIfPossible()
    }

    /// Creates the central (asks for Bluetooth permission the first time).
    func start() {
        guard central == nil else { return }
        state = "Starting Bluetooth…"
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    /// Forget the paired scooter (Scooter tab → Forget, and the developer tools).
    func forget() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        savedID = nil
        log("Scooter forgotten")
        if central?.state == .poweredOn { scan() }
    }

    private func scan() {
        state = "Looking for the scooter · switch it on"
        central?.scanForPeripherals(withServices: nil)
    }

    private func log(_ text: String) {
        // B04: which screen was open, to tell app-caused drops from radio drops
        let where_ = inBackground ? "app in background" : "app open · \(Screen.current)"
        let line = "\(Date().formatted(date: .abbreviated, time: .standard)) \(text) · \(where_)"
        events.append(line)
        if events.count > 300 { events.removeFirst(events.count - 300) }
        if eventsLoaded { defaults.set(events, forKey: Self.eventsKey) }
    }

    /// Merges the saved events with the ones logged before the data was readable.
    func loadEventsIfPossible() {
        guard !eventsLoaded, UIApplication.shared.isProtectedDataAvailable else { return }
        events = (defaults.stringArray(forKey: Self.eventsKey) ?? []) + events
        if events.count > 300 { events.removeFirst(events.count - 300) }
        eventsLoaded = true
        defaults.set(events, forKey: Self.eventsKey)
    }

    private func didBecomeConnected(_ p: CBPeripheral) {
        connected = true
        state = "Connected · waiting for data"
        p.discoverServices([CBUUID(string: ScooterGatt.dataService), CBUUID(string: ScooterGatt.deviceInformation)])
    }
}

extension ScooterLink: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
            log("iOS relaunched the app for the scooter")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            state = central.state == .unauthorized ? "Bluetooth permission is off" : "Bluetooth isn't available"
            return
        }
        if let known = peripheral, known.state == .connected {
            // B08: iOS relaunched the app with the scooter already connected: no didConnect comes,
            // so this is the connect (wake notification, checks, sensors)
            let background = inBackground
            connectedAt = Date()
            log("Connected (restored by iOS)")
            didBecomeConnected(known)
            connectHandlers.forEach { $0(background) }
        } else if let restored = peripheral {
            // Restored by iOS (e.g. before the first unlock, when the saved ID can't be read yet)
            state = "Waiting for the scooter · switch it on"
            central.connect(restored)
        } else if let id = savedID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
            known.delegate = self
            state = "Waiting for the scooter · switch it on"
            central.connect(known)     // pending connect: iOS completes it when the scooter appears
        } else {
            scan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = found.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let maker = [UInt8](advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data())
        guard ScooterGatt.isScooter(name: name, manufacturerData: maker) else { return }
        central.stopScan()
        peripheral = found
        found.delegate = self
        savedID = found.identifier
        state = "Found the scooter · connecting…"
        central.connect(found)
    }

    func centralManager(_ central: CBCentralManager, didConnect connectedPeripheral: CBPeripheral) {
        let background = inBackground
        connectedAt = Date()
        log("Connected")
        didBecomeConnected(connectedPeripheral)
        connectHandlers.forEach { $0(background) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        log("Connection failed\(error.map { ": \($0.localizedDescription)" } ?? "")")
        central.connect(failed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral, error: Error?) {
        connected = false
        assembler.reset()
        // B04: log iOS's reason (CBError code) and how long the link lasted
        let held = connectedAt.map { String(format: " after %.0f s", Date().timeIntervalSince($0)) } ?? ""
        connectedAt = nil
        let reason: String
        if let error = error as NSError? {
            reason = "CBError \(error.code): \(error.localizedDescription)"
        } else {
            reason = "no error (the app cancelled the connection)"
        }
        log("Disconnected\(held) · \(reason)")
        state = "Disconnected · waiting for the scooter"
        disconnectHandlers.forEach { $0(reason) }
        if savedID != nil || peripheral != nil { central.connect(lost) }   // pending connect, works in the background
    }
}

extension ScooterLink: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for service in p.services ?? [] {
            let id = service.uuid.uuidString
            if ScooterGatt.isDenied(id) {
                if !deniedSeen.contains(id) { deniedSeen.append(id) }
                continue
            }
            if ScooterGatt.normalized(id) == ScooterGatt.dataService {
                p.discoverCharacteristics([CBUUID(string: ScooterGatt.statusStream)], for: service)
            } else if ScooterGatt.normalized(id) == ScooterGatt.deviceInformation {
                p.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            let id = characteristic.uuid.uuidString
            if ScooterGatt.isDenied(id) {
                if !deniedSeen.contains(id) { deniedSeen.append(id) }
            } else if ScooterGatt.maySubscribe(id) {
                p.setNotifyValue(true, for: characteristic)
                state = "Connected · receiving data"
            } else if ScooterGatt.mayRead(characteristic: id, inService: service.uuid.uuidString),
                      characteristic.properties.contains(.read) {
                p.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if let service = characteristic.service,
           ScooterGatt.normalized(service.uuid.uuidString) == ScooterGatt.deviceInformation {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
                ?? Hex.string([UInt8](data), separator: "")
            deviceInfo.set(characteristic: characteristic.uuid.uuidString, value: text)
            return
        }
        guard ScooterGatt.maySubscribe(characteristic.uuid.uuidString) else { return }
        let bytes = [UInt8](data)
        let now = Date()
        let background = inBackground
        packets += 1
        if background { packetsInBackground += 1 }
        lastHex = Hex.string(bytes)
        if let f = assembler.ingest(bytes, at: now.timeIntervalSince(started)) {
            frame = f
        } else {
            unknownPackets += 1
        }
        packetHandlers.forEach { $0(bytes, now, background) }
    }
}
