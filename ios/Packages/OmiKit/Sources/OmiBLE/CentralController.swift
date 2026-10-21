@preconcurrency import CoreBluetooth
import Foundation
import OmiProtocol

public enum CentralState: String, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

    init(_ s: CBManagerState) {
        switch s {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .resetting: self = .resetting
        default: self = .unknown
        }
    }
}

public struct ScanCandidate: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var rssi: Int
    public var lastSeen: Date
}

/// Why connections are currently not accepted. Any suppression blocks every acceptance path.
public enum ReconnectSuppression: String, Sendable, Hashable {
    case userDisconnected, pairingLost, storageLow, unsupportedDevice, simulatedMode
}

public protocol CentralControllerDelegate: AnyObject {
    func centralDidUpdateState(_ state: CentralState)
    func centralDidDiscover(_ candidate: ScanCandidate)
    func centralDidConnect(_ transport: DeviceTransport)
    func centralDidDisconnect(_ identifier: UUID, error: Error?, pairingLost: Bool)
    func centralDidFailToConnect(_ identifier: UUID, error: Error?, pairingLost: Bool)
}

/// Pure classification of CoreBluetooth pairing failures (port of Omi `OmiBlePairingPolicy`).
public enum PairingPolicy {
    public static func isPairingLost(_ error: Error?) -> Bool {
        var current = error
        while let err = current {
            let ns = err as NSError
            if (ns.domain == CBErrorDomain || ns.domain == "CBErrorDomain"),
               ns.code == CBError.Code.peerRemovedPairingInformation.rawValue {
                return true
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }
}

// MARK: - Backend abstraction (CoreBluetooth in the app, fakes in tests)

public enum PeripheralConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected, disconnecting
}

public protocol PeripheralHandle: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var connectionState: PeripheralConnectionState { get }
    /// The transport owning this peripheral's delegate callbacks for the current connection
    /// (created on first use, attached immediately).
    func transport() -> DeviceTransport
    /// The link went down: the next connection gets a fresh transport.
    func resetTransport()
    /// The central reached powered-on: run GATT work deferred until then.
    func centralPoweredOn()
}

public protocol CentralBackend: AnyObject {
    var state: CentralState { get }
    func scan(serviceUUIDs: [String]?, allowDuplicates: Bool)
    func stopScan()
    func connect(_ p: PeripheralHandle)
    func cancelConnection(_ p: PeripheralHandle)
    func retrievePeripheral(_ id: UUID) -> PeripheralHandle?
}

public protocol CentralBackendEvents: AnyObject {
    func backendDidUpdateState(_ state: CentralState)
    func backendWillRestore(_ peripherals: [PeripheralHandle])
    func backendDidDiscover(_ p: PeripheralHandle, name: String?, services: [String], rssi: Int)
    func backendDidConnect(_ p: PeripheralHandle)
    func backendDidFailToConnect(_ p: PeripheralHandle, error: Error?)
    func backendDidDisconnect(_ p: PeripheralHandle, error: Error?)
}

// MARK: - Controller

/// Connection policy on top of a `CentralBackend` (all calls and callbacks on the engine queue).
///
/// - Created synchronously at launch with a restore identifier so iOS can relaunch the app into the
///   background for BLE events. Restored peripherals get their transport (delegate) attached in
///   `willRestoreState`, so buffered notifications and cached `isNotifying` state are not lost.
/// - Remembers one peripheral; reconnects with `retrievePeripheral` + a pending `connect` (never
///   times out), re-issues `connect` 200 ms after an unexpected disconnect and on foreground.
/// - Any suppression (user disconnect, `peerRemovedPairingInformation`, storage guard, unsupported
///   device, simulated mode) is enforced on **every** acceptance path: restoration, powered-on,
///   `didConnect`, remembered-device scan hits, explicit connects. Prohibited links are cancelled.
public final class CentralController: CentralBackendEvents, @unchecked Sendable {
    public static let restoreIdentifier = "omi-notes.central"

    public let queue: DispatchQueue
    public weak var delegate: CentralControllerDelegate?
    public var rememberedId: UUID?
    public private(set) var suppression: Set<ReconnectSuppression> = []
    public private(set) var isScanning = false
    public var reconnectDelay: TimeInterval = 0.2

    private var backend: CentralBackend!
    private var peripheral: PeripheralHandle?
    private var deliveredId: UUID?
    private var discovered: [UUID: PeripheralHandle] = [:]
    private var wantsScan = false
    private var scanningForRemembered = false
    private var prohibited: [PeripheralHandle] = []

    public convenience init(queue: DispatchQueue, rememberedId: UUID?, suppression: Set<ReconnectSuppression>) {
        self.init(queue: queue, rememberedId: rememberedId, suppression: suppression) { events in
            CoreBluetoothBackend(queue: queue, events: events)
        }
    }

    public init(queue: DispatchQueue, rememberedId: UUID?, suppression: Set<ReconnectSuppression>, backend makeBackend: (CentralBackendEvents) -> CentralBackend) {
        self.queue = queue
        self.rememberedId = rememberedId
        self.suppression = suppression
        backend = makeBackend(self)
    }

    public var state: CentralState { backend.state }

    /// Connections are accepted only for the remembered device and only without suppression.
    public var connectionAllowed: Bool { suppression.isEmpty && rememberedId != nil }

    private func mayAccept(_ p: PeripheralHandle) -> Bool { connectionAllowed && p.identifier == rememberedId }

    public func suppress(_ reason: ReconnectSuppression) { suppression.insert(reason) }
    public func unsuppress(_ reason: ReconnectSuppression) { suppression.remove(reason) }

    // MARK: Scanning (foreground pairing)

    public func startScan() {
        wantsScan = true
        guard backend.state == .poweredOn else { return }
        isScanning = true
        // DevKit 2's advertisement may omit the service UUID: scan everything and filter.
        backend.scan(serviceUUIDs: nil, allowDuplicates: true)
        log(.info, "ble", "scan started")
    }

    public func stopScan() {
        wantsScan = false
        guard isScanning || scanningForRemembered else { return }
        isScanning = false
        scanningForRemembered = false
        backend.stopScan()
    }

    // MARK: Connection

    /// User picked a device (the engine sets `rememberedId` and clears user-level suppression first)
    /// or asked to reconnect. Still refused while any suppression (e.g. storage guard) is active.
    public func connect(to id: UUID) {
        stopScan()
        guard connectionAllowed, id == rememberedId else {
            log(.warning, "ble", "not connecting to \(id): \(suppression.isEmpty ? "not the remembered device" : "suppressed (\(suppression.map(\.rawValue).sorted().joined(separator: ", ")))")")
            return
        }
        let p = discovered[id] ?? backend.retrievePeripheral(id)
        guard let p else {
            log(.warning, "ble", "device \(id) not known to the system; scanning for it")
            startScanForRemembered()
            return
        }
        if let old = peripheral, old.identifier != p.identifier, old.connectionState != .disconnected {
            backend.cancelConnection(old)
        }
        peripheral = p
        guard backend.state == .poweredOn else { return }
        if p.connectionState == .connected {
            if deliveredId != p.identifier { deliver(p) }
        } else {
            backend.connect(p)
        }
    }

    /// Idempotent: (re)issue a pending connect for the remembered device if allowed.
    public func ensureConnected() {
        guard backend.state == .poweredOn, connectionAllowed, let id = rememberedId else { return }
        if let p = peripheral, p.identifier == id {
            if p.connectionState == .connected {
                if deliveredId != p.identifier { deliver(p) }
                return
            }
            backend.connect(p)  // re-kick even while .connecting
            return
        }
        connect(to: id)
    }

    /// Cancels the link or pending connect (the caller sets the suppression reason first).
    public func disconnect() {
        if let p = peripheral, p.connectionState != .disconnected {
            backend.cancelConnection(p)
        }
    }

    public func forget() {
        disconnect()
        rememberedId = nil
        peripheral?.resetTransport()
        peripheral = nil
        deliveredId = nil
    }

    private func startScanForRemembered() {
        guard backend.state == .poweredOn, connectionAllowed else { return }
        scanningForRemembered = true
        // Service-filtered scans are allowed in the background.
        backend.scan(serviceUUIDs: [OmiUUID.audioService], allowDuplicates: false)
    }

    private func deliver(_ p: PeripheralHandle) {
        deliveredId = p.identifier
        delegate?.centralDidConnect(p.transport())
    }

    private func cancelProhibited() {
        guard backend.state == .poweredOn else { return }
        for p in prohibited where p.connectionState != .disconnected {
            log(.info, "ble", "cancelling prohibited link to \(p.identifier)")
            backend.cancelConnection(p)
        }
        prohibited.removeAll()
    }

    // MARK: CentralBackendEvents

    public func backendWillRestore(_ restored: [PeripheralHandle]) {
        log(.info, "ble", "state restoration with \(restored.count) peripheral(s)")
        for p in restored {
            guard p.identifier == rememberedId else {
                prohibited.append(p)
                continue
            }
            peripheral = p
            _ = p.transport()  // attach the delegate now: nothing delivered in between is lost
            switch p.connectionState {
            case .connected:
                if mayAccept(p) { deliver(p) } else { prohibited.append(p) }
            case .connecting:
                if !mayAccept(p) { prohibited.append(p) }
            default:
                break
            }
        }
        cancelProhibited()
    }

    public func backendDidUpdateState(_ state: CentralState) {
        log(.info, "ble", "bluetooth \(state.rawValue)")
        delegate?.centralDidUpdateState(state)
        guard state == .poweredOn else {
            if state == .poweredOff || state == .resetting, let p = peripheral, deliveredId == p.identifier {
                deliveredId = nil
                p.resetTransport()
                delegate?.centralDidDisconnect(p.identifier, error: nil, pairingLost: false)
            }
            return
        }
        cancelProhibited()
        if let p = peripheral {
            p.centralPoweredOn()
            if p.connectionState == .connected, deliveredId != p.identifier {
                if mayAccept(p) { deliver(p) } else { backend.cancelConnection(p) }
            } else if p.connectionState != .connected {
                ensureConnected()
            }
        } else {
            ensureConnected()
        }
        if wantsScan { startScan() }
    }

    public func backendDidDiscover(_ p: PeripheralHandle, name: String?, services: [String], rssi: Int) {
        if scanningForRemembered, p.identifier == rememberedId {
            scanningForRemembered = false
            if !isScanning { backend.stopScan() }
            guard connectionAllowed else { return }
            peripheral = p
            backend.connect(p)
            return
        }
        guard isScanning, DeviceScanFilter.isCandidate(name: name, advertisedServices: services) else { return }
        discovered[p.identifier] = p
        delegate?.centralDidDiscover(ScanCandidate(id: p.identifier, name: name ?? "Omi", rssi: rssi, lastSeen: Date()))
    }

    public func backendDidConnect(_ p: PeripheralHandle) {
        guard mayAccept(p) else {
            log(.warning, "ble", "refusing connection to \(p.identifier) (\(p.identifier == rememberedId ? "suppressed" : "not the remembered device"))")
            backend.cancelConnection(p)
            return
        }
        peripheral = p
        deliver(p)
    }

    public func backendDidFailToConnect(_ p: PeripheralHandle, error: Error?) {
        let lost = PairingPolicy.isPairingLost(error)
        if lost { suppression.insert(.pairingLost) }
        p.resetTransport()
        log(.warning, "ble", "connect failed: \(error?.localizedDescription ?? "unknown")")
        delegate?.centralDidFailToConnect(p.identifier, error: error, pairingLost: lost)
        scheduleReconnect(p)
    }

    public func backendDidDisconnect(_ p: PeripheralHandle, error: Error?) {
        let lost = PairingPolicy.isPairingLost(error)
        if lost { suppression.insert(.pairingLost) }
        let wasDelivered = deliveredId == p.identifier
        if wasDelivered { deliveredId = nil }
        p.resetTransport()
        log(.info, "ble", "disconnected: \(error?.localizedDescription ?? "clean")")
        delegate?.centralDidDisconnect(p.identifier, error: error, pairingLost: lost)
        scheduleReconnect(p)
    }

    private func scheduleReconnect(_ p: PeripheralHandle) {
        guard p.identifier == rememberedId else { return }
        // Peripheral handles are only ever touched on `queue`, which this closure also runs on.
        nonisolated(unsafe) let handle = p
        queue.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, self.connectionAllowed, self.backend.state == .poweredOn,
                  handle.identifier == self.rememberedId, handle.connectionState != .connected else { return }
            self.peripheral = handle
            self.backend.connect(handle)  // pending connect: free while the device is away
        }
    }
}

// MARK: - CoreBluetooth backend

final class CoreBluetoothBackend: NSObject, CentralBackend, CBCentralManagerDelegate {
    private var manager: CBCentralManager!
    private weak var events: CentralBackendEvents?
    private var handles: [UUID: CBPeripheralHandle] = [:]

    init(queue: DispatchQueue, events: CentralBackendEvents) {
        self.events = events
        super.init()
        manager = CBCentralManager(
            delegate: self, queue: queue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: CentralController.restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ])
    }

    var state: CentralState { CentralState(manager.state) }

    private func handle(_ p: CBPeripheral) -> CBPeripheralHandle {
        if let h = handles[p.identifier], h.peripheral === p { return h }
        let h = CBPeripheralHandle(peripheral: p) { [weak self] in self?.manager.state == .poweredOn }
        handles[p.identifier] = h
        return h
    }

    func scan(serviceUUIDs: [String]?, allowDuplicates: Bool) {
        manager.scanForPeripherals(
            withServices: serviceUUIDs?.map { CBUUID(string: $0) },
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }

    func stopScan() { manager.stopScan() }

    func connect(_ p: PeripheralHandle) {
        guard let h = p as? CBPeripheralHandle else { return }
        manager.connect(h.peripheral, options: nil)
    }

    func cancelConnection(_ p: PeripheralHandle) {
        guard let h = p as? CBPeripheralHandle else { return }
        manager.cancelPeripheralConnection(h.peripheral)
    }

    func retrievePeripheral(_ id: UUID) -> PeripheralHandle? {
        manager.retrievePeripherals(withIdentifiers: [id]).first.map(handle)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        events?.backendWillRestore(restored.map(handle))
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        events?.backendDidUpdateState(CentralState(central.state))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString.lowercased() } ?? []
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        events?.backendDidDiscover(handle(peripheral), name: name, services: services, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        events?.backendDidConnect(handle(peripheral))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        events?.backendDidFailToConnect(handle(peripheral), error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        events?.backendDidDisconnect(handle(peripheral), error: error)
    }
}

final class CBPeripheralHandle: PeripheralHandle {
    let peripheral: CBPeripheral
    private let isPoweredOn: () -> Bool
    private var current: CBDeviceTransport?

    init(peripheral: CBPeripheral, isPoweredOn: @escaping () -> Bool) {
        self.peripheral = peripheral
        self.isPoweredOn = isPoweredOn
    }

    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }

    var connectionState: PeripheralConnectionState {
        switch peripheral.state {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        default: return .disconnected
        }
    }

    func transport() -> DeviceTransport {
        if let current { return current }
        let t = CBDeviceTransport(peripheral: peripheral, isPoweredOn: isPoweredOn)
        current = t
        return t
    }

    func resetTransport() { current = nil }
    func centralPoweredOn() { current?.centralPoweredOn() }
}

// MARK: - CoreBluetooth transport

/// Adapts one `CBPeripheral` (one connection) to `DeviceTransport`.
///
/// Restoration-aware: adopts services/characteristics the system already has cached, reports an
/// already-notifying characteristic as subscribed without a fresh CoreBluetooth round trip, buffers
/// values that arrive before a session is attached, and defers GATT requests until the central is
/// powered on.
final class CBDeviceTransport: NSObject, DeviceTransport, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    private let isPoweredOn: () -> Bool
    weak var delegate: DeviceTransportDelegate? {
        didSet { flushBuffered() }
    }
    private var characteristics: [OmiCharacteristic: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var deferred: [() -> Void] = []
    private var buffered: [(OmiCharacteristic, Data?)] = []

    init(peripheral: CBPeripheral, isPoweredOn: @escaping () -> Bool) {
        self.peripheral = peripheral
        self.isPoweredOn = isPoweredOn
        super.init()
        peripheral.delegate = self
        adoptCached()
    }

    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var maximumWriteValueLength: Int { peripheral.maximumWriteValueLength(for: .withoutResponse) }
    var isSimulated: Bool { false }

    private func adoptCached() {
        for s in peripheral.services ?? [] {
            for ch in s.characteristics ?? [] {
                if let c = omi(ch) { characteristics[c] = ch }
            }
        }
    }

    /// Cached discovery is usable when the audio characteristic and every discovered service's
    /// characteristics are present.
    private var cacheComplete: Bool {
        guard let services = peripheral.services, !services.isEmpty, characteristics[.audioData] != nil else { return false }
        return services.allSatisfy { $0.characteristics != nil }
    }

    func centralPoweredOn() {
        let work = deferred
        deferred.removeAll()
        work.forEach { $0() }
    }

    private func whenPoweredOn(_ body: @escaping () -> Void) {
        if isPoweredOn() { body() } else { deferred.append(body) }
    }

    func discover() {
        if cacheComplete {
            delegate?.transport(self, didDiscover: Set(characteristics.keys), complete: true)
            return
        }
        whenPoweredOn { [weak self] in
            guard let self else { return }
            self.peripheral.discoverServices(OmiCharacteristic.serviceUUIDs.map { CBUUID(string: $0) })
        }
    }

    func read(_ c: OmiCharacteristic) {
        guard let ch = characteristics[c] else {
            delegate?.transport(self, didUpdateValue: nil, for: c, error: SessionError.disconnected)
            return
        }
        whenPoweredOn { [weak self] in self?.peripheral.readValue(for: ch) }
    }

    func write(_ data: Data, to c: OmiCharacteristic) {
        guard let ch = characteristics[c] else {
            delegate?.transport(self, didWriteTo: c, error: SessionError.disconnected)
            return
        }
        whenPoweredOn { [weak self] in self?.peripheral.writeValue(data, for: ch, type: .withResponse) }
    }

    func writeWithoutResponse(_ data: Data, to c: OmiCharacteristic) -> Bool {
        guard let ch = characteristics[c], peripheral.state == .connected, peripheral.canSendWriteWithoutResponse,
              data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else { return false }
        peripheral.writeValue(data, for: ch, type: .withoutResponse)
        return true
    }

    func setNotify(_ enabled: Bool, for c: OmiCharacteristic) {
        guard let ch = characteristics[c] else {
            delegate?.transport(self, didUpdateNotificationStateFor: c, enabled: false, error: SessionError.disconnected)
            return
        }
        if ch.isNotifying == enabled {
            // Already in the requested state (e.g. restored subscription): report it directly.
            delegate?.transport(self, didUpdateNotificationStateFor: c, enabled: enabled, error: nil)
            return
        }
        whenPoweredOn { [weak self] in self?.peripheral.setNotifyValue(enabled, for: ch) }
    }

    private func flushBuffered() {
        guard let delegate, !buffered.isEmpty else { return }
        let values = buffered
        buffered.removeAll()
        for (c, v) in values { delegate.transport(self, didUpdateValue: v, for: c, error: nil) }
    }

    private func omi(_ ch: CBCharacteristic) -> OmiCharacteristic? {
        guard let service = ch.service else { return nil }
        return OmiCharacteristic.find(service: service.uuid.uuidString, characteristic: ch.uuid.uuidString)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        if let error { log(.error, "ble", "service discovery failed: \(error.localizedDescription)") }
        // The audio service first, so its characteristics (and the subscription) come back first.
        let isAudio = { (s: CBService) in OmiCharacteristic.normalize(s.uuid.uuidString) == OmiUUID.audioService }
        let ordered = services.filter(isAudio) + services.filter { !isAudio($0) }
        pendingServices = ordered.count
        if ordered.isEmpty {
            delegate?.transport(self, didDiscover: [], complete: true)
            return
        }
        for s in ordered { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if let c = omi(ch) { characteristics[c] = ch }
        }
        pendingServices -= 1
        delegate?.transport(self, didDiscover: Set(characteristics.keys), complete: pendingServices <= 0)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = omi(characteristic) else { return }
        guard let delegate else {
            // Restored link delivering before a session is attached: keep audio, drop nothing.
            if c == .audioData || c == .button || c == .storageControl {
                buffered.append((c, characteristic.value))
                if buffered.count > 2000 { buffered.removeFirst(buffered.count - 2000) }
            }
            return
        }
        delegate.transport(self, didUpdateValue: characteristic.value, for: c, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = omi(characteristic) else { return }
        delegate?.transport(self, didWriteTo: c, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = omi(characteristic) else { return }
        delegate?.transport(self, didUpdateNotificationStateFor: c, enabled: characteristic.isNotifying, error: error)
    }
}
