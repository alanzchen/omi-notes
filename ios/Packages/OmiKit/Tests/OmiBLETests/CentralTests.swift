import CoreBluetooth
import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

// Central adapter tests (review #4, #11, #20): restoration timing, restored subscription state,
// suppression on every acceptance path, and omitted callbacks.

final class FakePeripheral: PeripheralHandle, @unchecked Sendable {
    let identifier: UUID
    var name: String? = "Omi"
    var connectionState: PeripheralConnectionState
    private(set) var current: FakeDeviceTransport?
    private(set) var transportsCreated = 0
    private(set) var poweredOnCalls = 0
    var configure: (FakeDeviceTransport) -> Void = { _ in }

    init(_ id: UUID, state: PeripheralConnectionState = .disconnected) {
        identifier = id
        connectionState = state
    }

    func transport() -> DeviceTransport {
        if let current { return current }
        let t = FakeDeviceTransport(identifier: identifier)
        configure(t)
        current = t
        transportsCreated += 1
        return t
    }

    func resetTransport() { current = nil }
    func centralPoweredOn() { poweredOnCalls += 1 }
}

final class FakeBackend: CentralBackend, @unchecked Sendable {
    var state: CentralState = .unknown
    var connects: [UUID] = []
    var cancels: [UUID] = []
    var scans: [[String]?] = []
    var known: [UUID: FakePeripheral] = [:]

    func scan(serviceUUIDs: [String]?, allowDuplicates: Bool) { scans.append(serviceUUIDs) }
    func stopScan() {}
    func connect(_ p: PeripheralHandle) {
        connects.append(p.identifier)
        if let f = p as? FakePeripheral, f.connectionState == .disconnected { f.connectionState = .connecting }
    }
    func cancelConnection(_ p: PeripheralHandle) {
        cancels.append(p.identifier)
        (p as? FakePeripheral)?.connectionState = .disconnected
    }
    func retrievePeripheral(_ id: UUID) -> PeripheralHandle? { known[id] }
}

final class RecordingCentralDelegate: CentralControllerDelegate {
    var connected: [DeviceTransport] = []
    var disconnected: [UUID] = []
    var states: [CentralState] = []
    func centralDidUpdateState(_ state: CentralState) { states.append(state) }
    func centralDidDiscover(_ candidate: ScanCandidate) {}
    func centralDidConnect(_ transport: DeviceTransport) { connected.append(transport) }
    func centralDidDisconnect(_ identifier: UUID, error: Error?, pairingLost: Bool) { disconnected.append(identifier) }
    func centralDidFailToConnect(_ identifier: UUID, error: Error?, pairingLost: Bool) {}
}

struct CentralHarness {
    let queue = DispatchQueue(label: "test.central")
    let backend = FakeBackend()
    let delegate = RecordingCentralDelegate()
    let controller: CentralController
    let x = UUID(uuidString: "0000000A-0000-4000-8000-000000000001")!
    let y = UUID(uuidString: "0000000B-0000-4000-8000-000000000002")!

    init(suppression: Set<ReconnectSuppression> = []) {
        let backend = self.backend
        controller = CentralController(queue: queue, rememberedId: x, suppression: suppression) { _ in backend }
        controller.delegate = delegate
        controller.reconnectDelay = 0.01
    }

    func on(_ body: () -> Void) { queue.sync(execute: body) }

    func drain(after seconds: Double = 0.05) {
        Thread.sleep(forTimeInterval: seconds)
        queue.sync {}
    }
}

@Suite struct CentralControllerTests {
    @Test func restoredConnectedPeripheralIsAttachedAndDeliveredBeforePoweredOn() throws {
        let h = CentralHarness()
        let p = FakePeripheral(h.x, state: .connected)
        h.on { h.controller.backendWillRestore([p]) }
        #expect(p.transportsCreated == 1, "delegate attached during willRestoreState")
        #expect(h.delegate.connected.count == 1, "session can start before powered-on")
        #expect(h.delegate.connected.first === p.current)
        h.backend.state = .poweredOn
        h.on { h.controller.backendDidUpdateState(.poweredOn) }
        #expect(h.delegate.connected.count == 1, "no second delivery")
        #expect(p.poweredOnCalls == 1, "deferred GATT work released")
        #expect(h.backend.cancels.isEmpty)
    }

    @Test func restoredLinkIsCancelledWhenSuppressed() throws {
        for reason: ReconnectSuppression in [.storageLow, .userDisconnected, .pairingLost] {
            let h = CentralHarness(suppression: [reason])
            let p = FakePeripheral(h.x, state: .connected)
            h.on { h.controller.backendWillRestore([p]) }
            #expect(h.delegate.connected.isEmpty, "\(reason)")
            #expect(h.backend.cancels.isEmpty, "cannot cancel before powered-on")
            h.backend.state = .poweredOn
            h.on { h.controller.backendDidUpdateState(.poweredOn) }
            #expect(h.backend.cancels == [h.x], "\(reason): prohibited restored link cancelled")
            #expect(h.delegate.connected.isEmpty)
            #expect(h.backend.connects.isEmpty)
        }
    }

    @Test func restoredForeignPeripheralIsCancelled() {
        let h = CentralHarness()
        let other = FakePeripheral(h.y, state: .connected)
        h.backend.state = .poweredOn
        h.on { h.controller.backendWillRestore([other]) }
        #expect(h.backend.cancels == [h.y])
        #expect(h.delegate.connected.isEmpty)
    }

    @Test func didConnectIsRefusedWhileSuppressed() {
        let h = CentralHarness(suppression: [.storageLow])
        h.backend.state = .poweredOn
        let p = FakePeripheral(h.x, state: .connected)
        h.on { h.controller.backendDidConnect(p) }
        #expect(h.backend.cancels == [h.x])
        #expect(h.delegate.connected.isEmpty)
    }

    @Test func explicitConnectIsRefusedWhileStorageLow() {
        let h = CentralHarness(suppression: [.storageLow])
        h.backend.state = .poweredOn
        h.backend.known[h.x] = FakePeripheral(h.x)
        h.on { h.controller.connect(to: h.x) }
        #expect(h.backend.connects.isEmpty)
    }

    @Test func rememberedScanHitDoesNotBypassSuppression() {
        let h = CentralHarness()
        h.backend.state = .poweredOn
        h.on { h.controller.connect(to: h.x) }  // unknown to the system → scan for it
        #expect(h.backend.scans.count == 1)
        h.on { h.controller.suppress(.storageLow) }
        h.on { h.controller.backendDidDiscover(FakePeripheral(h.x), name: "Omi", services: [OmiUUID.audioService], rssi: -50) }
        #expect(h.backend.connects.isEmpty)
    }

    @Test func reconnectsAfterDropOnlyWhenAllowed() {
        let h = CentralHarness()
        h.backend.state = .poweredOn
        let p = FakePeripheral(h.x, state: .connected)
        h.backend.known[h.x] = p
        h.on { h.controller.backendDidConnect(p) }
        p.connectionState = .disconnected
        h.on { h.controller.backendDidDisconnect(p, error: nil) }
        h.drain()
        #expect(h.backend.connects == [h.x], "pending connect re-issued")
        #expect(p.current == nil, "fresh transport per connection")
        h.on {
            h.controller.suppress(.userDisconnected)
            h.controller.backendDidDisconnect(p, error: nil)
        }
        h.drain()
        #expect(h.backend.connects == [h.x], "no reconnect after a user disconnect")
    }

    @Test func pairingLostSuppressesReconnect() {
        let h = CentralHarness()
        h.backend.state = .poweredOn
        let p = FakePeripheral(h.x)
        let error = NSError(domain: CBErrorDomain, code: CBError.Code.peerRemovedPairingInformation.rawValue)
        h.on { h.controller.backendDidDisconnect(p, error: error) }
        h.drain()
        #expect(h.controller.suppression.contains(.pairingLost))
        #expect(h.backend.connects.isEmpty)
    }

    @Test func omittedConnectCallbackIsRekickedOnForeground() {
        let h = CentralHarness()
        h.backend.state = .poweredOn
        h.backend.known[h.x] = FakePeripheral(h.x)
        h.on { h.controller.ensureConnected() }
        #expect(h.backend.connects == [h.x])
        // didConnect never arrives; the app comes to the foreground.
        h.on { h.controller.ensureConnected() }
        #expect(h.backend.connects == [h.x, h.x])
    }

    @Test func poweredOffEndsDeliveredConnection() {
        let h = CentralHarness()
        let p = FakePeripheral(h.x, state: .connected)
        h.backend.state = .poweredOn
        h.on { h.controller.backendDidConnect(p) }
        h.on { h.controller.backendDidUpdateState(.poweredOff) }
        #expect(h.delegate.disconnected == [h.x])
    }
}

@Suite struct RestoredSessionTests {
    /// #11: a restored link whose audio characteristic is already notifying (and whose services are
    /// cached) must start capturing without waiting for callbacks that never come.
    @Test func restoredNotifyingAudioStartsCaptureImmediately() throws {
        let h = SessionHarness()
        h.transport.cachedCharacteristics = Set(OmiCharacteristic.allCases)
        h.transport.alreadyNotifying = [.audioData]
        h.session.start()
        #expect(h.session.recorder.isActive, "capture began from the restored subscription")
        #expect(h.session.phase == .streaming)
        h.transport.audio(Data([1, 0, 0, 0xB8]))
        #expect(h.session.recorder.stats.totalRecords == 1)
    }
}
