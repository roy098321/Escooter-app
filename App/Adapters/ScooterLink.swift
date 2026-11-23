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
    /// N11-2 Garage: every scooter in use (not sold / lost / removed); the one that switches on is the one connected
    private static let garageIDsKey = "corckie.garagePeripheralIDs"
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
    /// T-00: this session's events with their time, for the "last 15 minutes" report
    @ObservationIgnored private(set) var timedEvents: [(at: Date, line: String)] = []

    /// D2 3b: why there is no connection when the phone's Bluetooth is the cause (nil = nothing wrong)
    enum BluetoothProblem: Equatable { case off, denied, unavailable }
    private(set) var bluetoothProblem: BluetoothProblem?
    /// D2 1b: connected to a scooter that is not saved yet; it is saved only when Connect is pressed (`confirmPairing`)
    private(set) var pairingPending = false
    /// D2 1a / 7f: "RND G100" (from the Bluetooth tag) for the scooter found, saved or not
    private(set) var foundModel: String?
    @ObservationIgnored private var candidates: [UUID: (peripheral: CBPeripheral, rssi: Int)] = [:]
    @ObservationIgnored private var pickScheduled = false
    @ObservationIgnored private var candidateName: String?
    @ObservationIgnored private var candidateMakerTagged = false
    /// N11-2: the other Garage scooters, waiting (pending connect) while none is connected
    @ObservationIgnored private var standby: [UUID: CBPeripheral] = [:]
    /// N11-2: "Add another scooter" is looking for a scooter that is not in the Garage yet
    private(set) var adding = false

    var hasKnownScooter: Bool { savedID != nil }
    var knownPeripheralID: String? { savedID?.uuidString }
    /// N11-2: the scooter shown in Add a scooter, before Connect
    var pendingPeripheralID: String? { pairingPending ? peripheral?.identifier.uuidString : nil }
    @ObservationIgnored private var connectedAt: Date?

    private var savedID: UUID? {
        get { defaults.string(forKey: Self.savedIDKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.savedIDKey) }
    }

    private var garageIDs: [UUID] {
        get { (defaults.stringArray(forKey: Self.garageIDsKey) ?? []).compactMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue.map(\.uuidString), forKey: Self.garageIDsKey) }
    }

    /// N11-2: the Garage's scooters in use (from GarageService); the saved one is always among them
    func setGarage(_ ids: [String]) {
        var list = ids.compactMap(UUID.init(uuidString:))
        if let s = savedID, !list.contains(s) { list.append(s) }
        garageIDs = list
        for id in standby.keys where !list.contains(id) {
            if let p = standby[id] { central?.cancelPeripheralConnection(p) }
            standby[id] = nil
        }
    }

    /// N11-2: Sold / Lost / Remove in the Garage: the app stops connecting to it; the next scooter in use (if any) is waited for
    func retire(_ id: String, next: String?) {
        guard let uuid = UUID(uuidString: id) else { return }
        garageIDs.removeAll { $0 == uuid }
        if let p = standby[uuid] { central?.cancelPeripheralConnection(p); standby[uuid] = nil }
        guard savedID == uuid else { return }
        guard let next, let nextID = UUID(uuidString: next) else { forget(); return }
        let wasConnected = connected && peripheral?.identifier == uuid
        savedID = nextID
        log("Garage: active scooter changed after Sold / Lost / Remove")
        if let p = peripheral, p.identifier == uuid { central?.cancelPeripheralConnection(p) }
        if !wasConnected { peripheral = nil; reconnectKnown() }   // else didDisconnect does it
    }

    /// N11-2: while no scooter is connected, wait for any Garage scooter (pending connects; iOS completes the first that switches on)
    private func waitForGarage() {
        guard let central, central.state == .poweredOn, !adding else { return }
        let others = garageIDs.filter { $0 != savedID }
        guard !others.isEmpty else { return }
        for p in central.retrievePeripherals(withIdentifiers: others) where standby[p.identifier] == nil {
            standby[p.identifier] = p
            p.delegate = self
            central.connect(p)
        }
    }

    /// N11-2: a scooter is connected: the others stop waiting (no connect / cancel churn while riding)
    private func stopWaitingForOthers(except id: UUID) {
        for (other, p) in standby where other != id { central?.cancelPeripheralConnection(p) }
        standby = standby.filter { $0.key == id }
    }

    /// N11-2: Scooter tab → Add another scooter: look for a scooter that is not in the Garage yet (the paired one is let go
    /// meanwhile); Connect in the sheet (`confirmPairing`) adds it, Cancel (`cancelPairing`) goes back to the known ones.
    func startAdding() {
        guard central?.state == .poweredOn else { return }
        adding = true
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        stopWaitingForOthers(except: UUID())
        candidates = [:]
        foundModel = nil
        log("Looking for another scooter (Garage)")
        scan()
    }

    private func reconnectKnown() {
        guard let central, central.state == .poweredOn else { return }
        if let id = savedID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
            known.delegate = self
            central.connect(known)
        }
        waitForGarage()
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
        if let id = savedID { garageIDs.removeAll { $0 == id } }   // N11-2: a forgotten scooter leaves the Garage's connect list
        savedID = nil
        pairingPending = false
        adding = false
        candidates = [:]
        foundModel = nil
        log("Scooter forgotten")
        if central?.state == .poweredOn { scan() }
    }

    /// D2 1b: Connect was pressed in onboarding: the scooter being shown is now the paired one.
    func confirmPairing() {
        guard pairingPending, let p = peripheral else { return }
        savedID = p.identifier
        pairingPending = false
        if !garageIDs.contains(p.identifier) { garageIDs.append(p.identifier) }   // N11-2
        adding = false
        log("Scooter paired (Connect pressed)")
    }

    /// D2 1b: onboarding left without Connect: the scooter that was only being looked at is let go and nothing is saved.
    func cancelPairing() {
        guard pairingPending || adding else { return }
        if adding { central?.stopScan() }
        pairingPending = false
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        foundModel = nil
        log("Scooter not paired (setup left without Connect)")
        if adding {   // N11-2: Add another scooter cancelled: back to the known scooters
            adding = false
            reconnectKnown()
        }
    }

    /// D2 1b: after a short listen, connect to the strongest signal (the closest scooter), without saving it.
    private func connectClosest() {
        pickScheduled = false
        guard savedID == nil || adding, let best = candidates.values.max(by: { $0.rssi < $1.rssi }) else { return }
        candidates = [:]
        central?.stopScan()
        peripheral = best.peripheral
        best.peripheral.delegate = self
        pairingPending = true
        foundModel = KnownScooters.modelName(advertisedName: candidateName, makerTagged: candidateMakerTagged)
        state = "Found the scooter \u{00B7} connecting\u{2026}"
        central?.connect(best.peripheral)
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
        Diary.shared.note("bluetooth", "\(text) · \(where_)")   // B81: kept 30 days, also after iOS closes the app
        timedEvents.append((Date(), line))
        if timedEvents.count > 300 { timedEvents.removeFirst(timedEvents.count - 300) }
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
        deviceInfo = DeviceInfo()   // N11-2: re-read per connection (it may be another scooter of the Garage)
        // N11-5: a reconnect without a fresh scan still knows the model from the peripheral's name (G500 is not named "RND G100")
        if foundModel == nil, let name = p.name, ScooterGatt.knownNames[name] != nil {
            foundModel = KnownScooters.modelName(advertisedName: name, makerTagged: false)
        }
        frame = nil              // B73 (batch 3): no reading from an earlier connection is shown as now
        assembler.reset()
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
        switch central.state {
        case .poweredOn: bluetoothProblem = nil
        case .unauthorized: bluetoothProblem = .denied
        case .poweredOff: bluetoothProblem = .off
        case .unsupported: bluetoothProblem = .unavailable
        default: bluetoothProblem = nil      // resetting / unknown: transient
        }
        guard central.state == .poweredOn else {
            state = central.state == .unauthorized ? "Bluetooth permission is off" : "Bluetooth isn't available"
            return
        }
        if let known = peripheral, known.state == .connected {
            // B08: iOS relaunched the app with the scooter already connected: no didConnect comes,
            // so this is the connect (wake notification, checks, sensors)
            let background = inBackground
            connectedAt = Date()
            PlugInStore.noteConnect(atMs: Int64(Date().timeIntervalSince1970 * 1000))
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
            waitForGarage()            // N11-2: or any other scooter of the Garage
        } else {
            scan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = found.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let maker = [UInt8](advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data())
        guard ScooterGatt.isScooter(name: name, manufacturerData: maker) else { return }
        // N11-2: Add another scooter only offers a scooter that is not in the Garage yet
        if adding, found.identifier == savedID || garageIDs.contains(found.identifier) { return }
        guard savedID == nil || adding else { return }
        // D2 1b: nothing is saved here. Listen for two seconds, then connect to the closest; Connect saves it.
        candidates[found.identifier] = (found, RSSI.intValue == 127 ? -127 : RSSI.intValue)
        candidateName = name
        candidateMakerTagged = !maker.isEmpty
        if !pickScheduled {
            pickScheduled = true
            state = "Found a scooter \u{00B7} choosing the closest\u{2026}"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectClosest() }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect connectedPeripheral: CBPeripheral) {
        // N11-2 Garage: another of the rider's scooters switched on first: it becomes the active one
        if connectedPeripheral.identifier != peripheral?.identifier, standby[connectedPeripheral.identifier] != nil {
            if connected {
                central.cancelPeripheralConnection(connectedPeripheral)   // one scooter at a time; it waits again after this ride
                standby[connectedPeripheral.identifier] = nil
                return
            }
            if let old = peripheral {
                central.cancelPeripheralConnection(old)
                standby[old.identifier] = old
            }
            peripheral = connectedPeripheral
            savedID = connectedPeripheral.identifier
            foundModel = nil
            log("Switched to another scooter of the Garage")
        }
        stopWaitingForOthers(except: connectedPeripheral.identifier)
        let background = inBackground
        connectedAt = Date()
        PlugInStore.noteConnect(atMs: Int64(Date().timeIntervalSince1970 * 1000))   // F-31b: the Plug in pill goes at the next connect
        log("Connected")
        didBecomeConnected(connectedPeripheral)
        connectHandlers.forEach { $0(background) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        log("Connection failed\(error.map { ": \($0.localizedDescription)" } ?? "")")
        central.connect(failed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral, error: Error?) {
        // N11-2: a Garage scooter let go while another one is the active one: nothing changes for the active connection
        if let active = peripheral, lost.identifier != active.identifier {
            log("Other Garage scooter let go")
            return
        }
        connected = false
        assembler.reset()
        frame = nil              // B73 (batch 3)
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
        guard !adding else { return }   // N11-2: Add another scooter is scanning; Cancel reconnects the known ones
        if let s = savedID, s != lost.identifier { peripheral = nil; reconnectKnown(); return }   // N11-2: it left the Garage
        if savedID != nil || peripheral != nil { central.connect(lost) }   // pending connect, works in the background
        waitForGarage()   // N11-2: and wait for the rider's other scooters too
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
