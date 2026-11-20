import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol
import OmiWatchKit

/// Nightly 2026-11-20 UX (Devices): states that read as fine while they aren't.
@Suite struct DevicesHonestyTests {
    let now = Date(timeIntervalSince1970: 1_795_000_000)

    /// Alan's Watch, build 60: three parts whose transfers stopped moving 11 days ago. The Devices card said
    /// "Not recording" / "2 min waiting on the Watch" with no mark, as if they were simply queued.
    @Test func aWatchWhoseWaitingPartsAllStalledSaysSoOnTheCard() {
        let stalled = WatchReport(state: .idle, since: nil, waitingParts: 3, waitingSeconds: 140, at: now.addingTimeInterval(-60),
                                  stats: ["orphan_parts": 0, "outstanding_stalled": 3])
        let s = WatchSummary.evaluate(installed: true, report: stalled, lastReceivedAt: now.addingTimeInterval(-11 * 86400), now: now)
        #expect(s.cardDetail == "3 parts stuck on the Watch")
        #expect(s.tone == .attention)
        // moving, or only partly stalled: still the waiting length, quiet
        var moving = stalled
        moving.stats = ["orphan_parts": 0, "outstanding_stalled": 1, "outstanding_active": 2]
        let m = WatchSummary.evaluate(installed: true, report: moving, lastReceivedAt: now.addingTimeInterval(-11 * 86400), now: now)
        #expect(m.cardDetail == "2 min waiting on the Watch" && m.tone == .quiet)
        // a part arrived minutes ago: not called stuck yet
        let recent = WatchSummary.evaluate(installed: true, report: stalled, lastReceivedAt: now.addingTimeInterval(-120), now: now)
        #expect(recent.cardDetail == "2 min waiting on the Watch")
    }
}

/// An automatic reconnect is the engine doing its job: it isn't something that "needs you". Build 60 field log: the
/// reason is CoreBluetooth's own text, and nothing removed the line once the pendant streamed again.
@Suite(.serialized) struct ReconnectAttentionTests {
    @Test func anAutomaticReconnectLeavesNothingOnHome() async throws {
        let x = UUID(uuidString: "0000000A-0000-4000-8000-0000000000D2")!
        let backend = FakeBackend()
        let p = FakePeripheral(x, state: .connected)
        p.configure = {
            $0.values = FakeDeviceTransport.cv1Values()
            $0.cachedCharacteristics = []
            $0.discoveryFailure = "service discovery failed: The specified device is not connected."
        }
        backend.known[x] = p
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-reconnect-\(UUID().uuidString)")
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
        engine.queue.sync { events.backendDidUpdateState(.poweredOn) }
        engine.queue.sync { events.backendDidConnect(p) }
        engine.queue.sync {}
        #expect(engine.snapshotNow().attention.isEmpty, "\(engine.snapshotNow().attention)")
    }
}
