import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// Since 5a802a0 a failed discovery reconnects instead of refusing. A pendant whose discovery fails on every connection
/// would then reconnect every ~connection setup, forever. From the third failure in a row it backs off (30 s doubling
/// to 5 min; shortened here), never refused or suppressed; any success, the foreground, Reconnect, pair or forget
/// resets it, and a user Disconnect during a backoff wins.
@Suite(.serialized) struct DiscoveryBackoffTests {
    final class Rig {
        let x = UUID(uuidString: "0000000A-0000-4000-8000-0000000000D3")!
        let backend = FakeBackend()
        let p: FakePeripheral
        var failing = true
        let engine: OmiEngine
        let events: CentralBackendEvents
        let root: URL

        init() throws {
            p = FakePeripheral(x, state: .disconnected)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-backoff-\(UUID().uuidString)")
            backend.known[x] = p
            var config = EngineConfiguration(dirs: CaptureDirectories(root: root), appVersion: "t", useCoreBluetooth: false, tickInterval: 0.2)
            config.discoveryBackoffBase = 0.6
            let sink = Locked<CentralBackendEvents?>(nil)
            let backend = self.backend
            config.testCentralBackend = { events in
                sink.value = events
                backend.state = .poweredOn
                return backend
            }
            engine = OmiEngine(config: config, settings: try EngineReviewRegressionTests().makeSettings(remembered: x), uploadTransport: CountingUploadTransport())
            events = try #require(sink.value)
            p.configure = { [unowned self] in
                $0.values = FakeDeviceTransport.cv1Values()
                if self.failing {
                    $0.cachedCharacteristics = []
                    $0.discoveryFailure = "service discovery failed: The specified device is not connected."
                } else {
                    $0.cachedCharacteristics = Set(OmiCharacteristic.allCases)
                    $0.alreadyNotifying = [.audioData]
                }
            }
            engine.queue.sync { events.backendDidUpdateState(.poweredOn) }
        }

        /// One connection that discovers (failing or not); returns the connects issued within `window` after it.
        func connectOnce(window: Double) async throws -> Int {
            engine.queue.sync {
                p.connectionState = .connected
                p.resetTransport()
                events.backendDidConnect(p)
            }
            let before = engine.queue.sync { backend.connects.count }
            try await Task.sleep(for: .seconds(window))
            return engine.queue.sync { backend.connects.count } - before
        }

        func connects(within window: Double) async throws -> Int {
            let before = engine.queue.sync { backend.connects.count }
            try await Task.sleep(for: .seconds(window))
            return engine.queue.sync { backend.connects.count } - before
        }
    }

    @Test func theThirdFailureInARowBacksOffInsteadOf200ms() async throws {
        let r = try Rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(try await r.connectOnce(window: 0.35) == 1, "1st failure: the usual 200 ms reconnect")
        #expect(try await r.connectOnce(window: 0.35) == 1, "2nd failure: the usual 200 ms reconnect")
        #expect(try await r.connectOnce(window: 0.35) == 0, "3rd failure: no reconnect at 200 ms")
        #expect(try await r.connects(within: 0.6) == 1, "the backoff ends in a reconnect: never a refusal")
        #expect(!r.engine.snapshotNow().attention.contains { $0.hasPrefix("Not recording") })
    }

    @Test func aSuccessfulConnectionOrReconnectResetsTheBudget() async throws {
        let r = try Rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        for _ in 0..<3 { _ = try await r.connectOnce(window: 0.3) }
        // Reconnect during the backoff connects at once
        let before = r.engine.queue.sync { r.backend.connects.count }
        r.engine.reconnect()
        r.engine.queue.sync {}
        #expect(r.engine.queue.sync { r.backend.connects.count } - before == 1)
        // a good connection, then failures count from zero again
        r.failing = false
        _ = try await r.connectOnce(window: 0.1)
        #expect(r.engine.session != nil)
        r.failing = true
        r.engine.queue.sync { r.events.backendDidDisconnect(r.p, error: nil) }  // that link ends
        _ = try await r.connects(within: 0.35)
        #expect(try await r.connectOnce(window: 0.35) == 1, "a failure after a success is the 1st again")
    }

    @Test func aUserDisconnectDuringTheBackoffWins() async throws {
        let r = try Rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        for _ in 0..<3 { _ = try await r.connectOnce(window: 0.3) }
        r.engine.disconnect()
        #expect(try await r.connects(within: 1.0) == 0, "no reconnect after the user disconnected")
    }
}
