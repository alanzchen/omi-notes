import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// Field log, build 60, 2026-11-19 20:10:32Z: a restored link to Alan's own pendant was already gone; service discovery
/// failed ("The specified device is not connected.") and reported no services, the session refused the pendant as "not
/// an Omi device", and the engine suppressed reconnecting to it for the rest of that process. A discovery that failed
/// (an error, or a link that is no longer connected) is a link problem: reconnect, never refuse. Only a complete,
/// error-free discovery on a live link without the audio characteristic refuses.
@Suite struct DiscoveryFailureTests {
    static let notConnected = "service discovery failed: The specified device is not connected."

    @Test func aFailedServiceDiscoveryReconnectsInsteadOfRefusing() {
        let h = SessionHarness()
        h.transport.cachedCharacteristics = []
        h.transport.discoveryFailure = Self.notConnected
        h.session.start()
        if case .refused = h.session.phase { Issue.record("refused: \(h.session.phase)") }
        #expect(h.delegate.disconnectRequests.isEmpty, "no refusal, no suppression")
        #expect(h.delegate.reconnectRequests == [Self.notConnected])
    }

    @Test func aFailedCharacteristicDiscoveryWithoutAudioReconnectsInsteadOfRefusing() {
        let h = SessionHarness()
        h.transport.cachedCharacteristics = [.batteryLevel, .modelNumber]
        h.transport.discoveryFailure = "characteristic discovery failed: The specified device is not connected."
        h.session.start()
        if case .refused = h.session.phase { Issue.record("refused: \(h.session.phase)") }
        #expect(h.delegate.disconnectRequests.isEmpty)
        #expect(h.delegate.reconnectRequests.count == 1)
    }

    /// What `CBDeviceTransport` reports when its last discovery callback arrives.
    @Test func theCoreBluetoothTransportTrustsOnlyAnErrorFreeDiscoveryOnALiveLink() {
        #expect(CBDeviceTransport.discoveryFailure(error: nil, connected: true) == nil)
        #expect(CBDeviceTransport.discoveryFailure(error: Self.notConnected, connected: true) == Self.notConnected)
        #expect(CBDeviceTransport.discoveryFailure(error: nil, connected: false) == "the link dropped during discovery")
        #expect(CBDeviceTransport.discoveryFailure(error: "characteristic discovery failed: x", connected: false) == "characteristic discovery failed: x")
    }

    /// A genuinely connected device whose discovery finished without an error and has no audio characteristic is still
    /// not an Omi: refused, and not reconnected to.
    @Test func aCompleteErrorFreeDiscoveryWithoutAudioStillRefuses() {
        let h = SessionHarness()
        h.transport.cachedCharacteristics = [.batteryLevel, .modelNumber]
        h.session.start()
        #expect(h.session.phase == .refused("not an Omi device (no audio characteristic)"))
        #expect(h.delegate.disconnectRequests.count == 1 && h.delegate.disconnectRequests.first?.1 == true)
        #expect(h.delegate.reconnectRequests.isEmpty)
    }

    /// Audio that arrived before the rest of discovery failed stays: the link goes on (the audio characteristic is
    /// there), and when the link then drops the capture is sealed with every byte received, not quarantined.
    @Test func audioReceivedBeforeADiscoveryErrorIsKept() throws {
        let h = SessionHarness()
        h.session.start()
        h.transport.delegate?.transport(h.transport, didDiscover: [.audioData, .audioCodec], complete: false)
        h.transport.confirmAudioSubscription()
        for i in 0..<20 { h.transport.audio(Data([UInt8(i), 0, 0, 0xF8, 0xFF, 0xFE])) }
        h.transport.discoveryFailure = "characteristic discovery failed: Unknown ATT error."
        h.transport.delegate?.transport(h.transport, didDiscover: [.audioData, .audioCodec], complete: true)
        if case .refused = h.session.phase { Issue.record("refused: \(h.session.phase)") }
        #expect(h.delegate.disconnectRequests.isEmpty)
        h.session.end(reason: .bleDisconnected)
        #expect(FileIO.contents(of: h.dirs.journalQuarantine).isEmpty, "nothing set aside")
        #expect(!h.outbox.pending().isEmpty, "the audio received is sealed for upload")
    }
}

/// The same field sequence through the engine and the central: the pendant must stay connectable.
@Suite(.serialized) struct DiscoveryFailureEngineTests {
    @Test func aLinkLostDuringDiscoveryKeepsReconnectingToThePendant() async throws {
        let x = UUID(uuidString: "0000000A-0000-4000-8000-0000000000D1")!
        let backend = FakeBackend()
        let p = FakePeripheral(x, state: .connected)
        var failing = true
        p.configure = {
            $0.values = FakeDeviceTransport.cv1Values()
            if failing {
                $0.cachedCharacteristics = []
                $0.discoveryFailure = DiscoveryFailureTests.notConnected
            } else {
                $0.cachedCharacteristics = Set(OmiCharacteristic.allCases)
                $0.alreadyNotifying = [.audioData]
            }
        }
        backend.known[x] = p
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false, tickInterval: 0.2)
        let sink = Locked<CentralBackendEvents?>(nil)
        config.testCentralBackend = { events in
            sink.value = events
            backend.state = .poweredOn
            return backend
        }
        let engine = OmiEngine(config: config, settings: try EngineReviewRegressionTests().makeSettings(remembered: x), uploadTransport: CountingUploadTransport())
        let events = try #require(sink.value)
        // restoration hands over a link CoreBluetooth still calls connected; it is already gone
        engine.queue.sync { events.backendWillRestore([p]) }
        engine.queue.sync { p.connectionState = .disconnected }
        engine.queue.sync { events.backendDidUpdateState(.poweredOn) }
        engine.queue.sync {}
        #expect(!engine.snapshotNow().attention.contains { $0.hasPrefix("Not recording") }, "no refusal shown")
        // a reconnect is pending (CoreBluetooth sends no disconnect for a link it had already lost)
        let before = backend.connects.count
        try await Task.sleep(for: .milliseconds(600))
        engine.queue.sync {}
        #expect(backend.connects.count > before, "a pending connect to the pendant is issued again")
        // and the next connection is accepted and records
        failing = false
        engine.queue.sync {
            p.connectionState = .connected
            p.resetTransport()
            events.backendDidConnect(p)
        }
        #expect(engine.session != nil, "the pendant is not suppressed")
        #expect(p.transportsCreated == 2)
    }
}
