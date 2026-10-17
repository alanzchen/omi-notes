import Foundation
import Testing
@testable import OmiBLE
import OmiCapture
import OmiProtocol

/// A local transport that reports progress like `BackgroundSessionTransport` (`didSendBodyData`);
/// nothing goes over a network.
final class ProgressTransport: UploadTransport, UploadProgressReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [String] = []
    var onProgress: ((String, Int64, Int64) -> Void)?
    var started: [String] { lock.lock(); defer { lock.unlock() }; return _started }
    func activeTaskIdentifiers(_ completion: @escaping @Sendable (Set<String>) -> Void) { completion(Set(started)) }
    func startUpload(_ request: URLRequest, fromFile: URL, identifier: String, earliestBeginDate: Date?) {
        lock.lock(); _started.append(identifier); lock.unlock()
    }
    func cancel(identifiers: Set<String>) { lock.lock(); _started.removeAll { identifiers.contains($0) }; lock.unlock() }
    func cancelAll() { lock.lock(); _started.removeAll(); lock.unlock() }
}

/// The Devices transfer view reads `EngineSnapshot.transfer`: it must be fed by the real upload
/// path (progress callbacks, uploader outcomes, the outbox's own chunk headers), synthetic bytes only.
@Suite(.serialized) struct TransferEngineTests {
    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func chunk(_ outbox: Outbox, seq: Int, seconds: Double) throws {
        let payload = Data(repeating: 1, count: 640)
        let h = EnvelopeHeader(
            captureId: "cap-transfer", chunkSequence: seq, deviceId: "dev", deviceName: nil, modelNumber: nil, firmwareRevision: nil,
            hardwareRevision: nil, source: .watchMic, payloadFormat: .pcm16leV1, codecId: 0,
            captureStartedAt: "2026-10-17T10:00:00.000Z", chunkStartOffsetUs: 0, chunkEndOffsetUs: Int64(seconds * 1e6), clockQuality: .phoneAnchored,
            timezone: nil, recordCount: 320, payloadBytes: payload.count, offlineStorage: nil, ring: nil, appVersion: nil)
        _ = try outbox.write(try Envelope.build(header: h, payload: payload), kind: .chunk(captureId: "cap-transfer", sequence: seq))
    }

    @Test func liveTransferNumbersComeFromTheRealUploadPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omi-transfer-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "omi-transfer-\(UUID().uuidString)")!, tokens: InMemoryTokenStore())
        try settings.setServer(url: URL(string: "https://mac.tail1234.ts.net")!, token: "tok-transfer")
        let dirs = CaptureDirectories(root: root)
        try dirs.create()
        let outbox = Outbox(dirs: dirs)
        try chunk(outbox, seq: 0, seconds: 12.5)
        try chunk(outbox, seq: 1, seconds: 12.5)
        _ = try outbox.write(Data("not an envelope".utf8), kind: .chunk(captureId: "cap-broken", sequence: 0))
        let transport = ProgressTransport()
        let engine = OmiEngine(config: EngineConfiguration(dirs: dirs, appVersion: "t", timezone: "UTC", useCoreBluetooth: false),
                               settings: settings, uploadTransport: transport)
        engine.appDidBecomeActive()
        #expect(await waitFor(5) { transport.started.contains { $0.hasSuffix("chunk_cap-transfer_000000.omnc") } })
        let launchId = try #require(transport.started.first { $0.hasSuffix("chunk_cap-transfer_000000.omnc") })
        // "Retry now": a new epoch, so new attempts begin while counting (the launch ones are obsolete)
        engine.retryUploads()
        #expect(await waitFor(5) { transport.started.contains { $0.hasSuffix("chunk_cap-transfer_000000.omnc") && $0 != launchId } })
        let id = try #require(transport.started.first { $0.hasSuffix("chunk_cap-transfer_000000.omnc") && $0 != launchId })

        let queued = engine.snapshotNow().transfer
        #expect(queued.pendingAudioSeconds == 25, "from the chunks' own headers: \(queued.pendingAudioSeconds)")
        #expect(queued.pendingAudioUnknown == 1, "an unreadable chunk stays unknown, not guessed")
        #expect(queued.meter.since != nil, "counting while the app is open")

        engine.queue.sync { transport.onProgress?(id, 600, 1_000) }  // a single first report (no zero-byte one)
        let live = engine.snapshotNow().transfer.meter
        // every attempt handed to iOS is tracked from its start (its file size is the known total)
        let handed = transport.started.filter { $0.hasPrefix("1.2|") }.count
        #expect(live.networkBytes == 600, "a single first report counts in full")
        #expect(live.inFlight.uploads == handed && live.inFlight.sent == 600 && live.inFlight.unknownTotals == 0)

        engine.queue.sync { engine.uploader.handleCompletion(identifier: id, statusCode: 201, body: nil, error: nil) }
        #expect(engine.snapshotNow().transfer.meter.deliveredAudioFiles == 1)
        engine.queue.sync { engine.uploader.handleCompletion(identifier: id, statusCode: 200, body: nil, error: nil) }
        #expect(engine.snapshotNow().transfer.meter.deliveredAudioFiles == 1, "acknowledged once, counted once")
        #expect(engine.snapshotNow().transfer.meter.inFlight.uploads == handed - 1, "the acknowledged one left")

        // UX-LT-ASTRA-04: a late report from an obsolete configuration/epoch counts nothing, leaves nothing
        engine.queue.sync { transport.onProgress?(launchId, 900, 1_000) }  // the obsolete launch attempt reports late
        let after = engine.snapshotNow().transfer.meter
        #expect(after.networkBytes == 600 && after.inFlight.uploads == handed - 1, "bytes \(after.networkBytes), uploads \(after.inFlight.uploads)")

        engine.appDidEnterBackground()
        engine.queue.sync {}
        #expect(engine.snapshotNow().transfer.meter.since == nil, "in the background nothing is live")
    }
}
